import Foundation
@preconcurrency import AVFoundation
import CoreMedia
@preconcurrency import Speech
import ScreenCaptureKit
import Accelerate

/// リアルタイム音声キャプチャ（マイク ＆ ScreenCaptureKit システム音声）と
/// 連続音声認識（SFSpeechRecognizer）を実行するネイティブストリーミングエンジン
public final class LiveAudioStreamEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "com.mnemosift.livestream.queue")

    // 音声認識
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var currentTaskGeneration: UInt64 = 0
    private var taskStartTime: Date = Date()
    private var lastResultReceivedTime: Date = Date()
    private var lastVoiceEnergyDetectedTime: Date = .distantPast
    private var continuousVoiceFramesCount: Int = 0
    private var hotwords: [String] = []
    private var useOnDeviceRecognition: Bool = false
    private var selectedSTTModel: AIModel?
    public private(set) var activeSTTModelName: String = "Apple SpeechAnalyzer"

    // 1タスク内での連続差分スライス管理 ＆ 重複防止
    private var committedCharCountInCurrentTask: Int = 0
    private var latestFullTaskTranscription: String = ""
    private var currentProvisionalText: String = ""
    private var lastCommittedUtteranceText: String = ""

    // タスク切り替え時の頭切れを防ぐプリロールバッファ（直近約1.5秒分）
    private var preRollPCMChunks: [AVAudioPCMBuffer] = []
    private let maxPreRollChunks = 12

    // 共通オーディオフォーマット (16kHz モノラル Float32)
    private let commonAudioFormat: AVAudioFormat

    // マイクキャプチャ
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var isMicrophoneActive: Bool = false

    // システム音声キャプチャ (ScreenCaptureKit)
    private var systemAudioStream: SCStream?
    private var systemAudioRingBuffer: [Float] = []
    private let maxRingBufferSamples = 16000 * 3 // 最大3秒分保持

    // 状態管理
    private var isRunningInternal: Bool = false
    private var activeSource: AudioSourceType = .microphoneAndSystem
    private var lastSpokenTime: Date = Date()
    private var silenceWatchdogTimer: DispatchSourceTimer?

    // コールバック
    public var onLevelMeterUpdate: (@Sendable (Double) -> Void)?
    public var onProvisionalTextUpdate: (@Sendable (String) -> Void)?
    public var onFinalizedUtterance: (@Sendable (String, Double, Double) -> Void)?
    public var onError: (@Sendable (String) -> Void)?

    private var sessionStartTime: Date = Date()
    private var currentUtteranceStartSeconds: Double = 0.0

    public override init() {
        self.commonAudioFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000.0,
            channels: 1,
            interleaved: false
        )!
        super.init()
        self.speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    }

    deinit {
        stop()
    }

    // MARK: - バンドル・権限チェック

    public static var canSafelyUseSpeechRecognizerTCC: Bool {
        if ProcessInfo.processInfo.environment["MNEMOSIFT_LAUNCHED_AS_APP"] == "1" {
            return true
        }
        let bundlePath = Bundle.main.bundlePath
        let execPath = ProcessInfo.processInfo.arguments.first ?? ""
        if bundlePath.contains(".xctest") || execPath.contains("swiftpm-testing-helper") {
            return false
        }
        return bundlePath.hasSuffix(".app") && Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil
    }

    public static func requestPermissions() async -> (mic: Bool, speech: Bool) {
        let micStatus = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }

        guard canSafelyUseSpeechRecognizerTCC else {
            return (micStatus, false)
        }

        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }

        return (micStatus, speechStatus)
    }

    public static func checkSystemAudioScreenCaptureAccess() -> Bool {
        if #available(macOS 14.0, *) {
            return CGPreflightScreenCaptureAccess()
        }
        return true
    }

    public static func requestSystemAudioScreenCaptureAccess() {
        if #available(macOS 14.0, *) {
            CGRequestScreenCaptureAccess()
        }
    }

    // MARK: - 録音・文字起こし開始

    public func updateActiveSTTModel(_ sttModel: AIModel) {
        stateQueue.sync {
            self.selectedSTTModel = sttModel
            self.activeSTTModelName = sttModel.name
        }
    }

    public func start(
        source: AudioSourceType,
        destinationWAVURL: URL,
        hotwords: [String] = [],
        sttModel: AIModel? = nil
    ) throws {
        var startError: Error?

        stateQueue.sync {
            guard !self.isRunningInternal else { return }

            self.activeSource = source
            self.selectedSTTModel = sttModel
            self.activeSTTModelName = sttModel?.name ?? "Apple SpeechAnalyzer"
            self.sessionStartTime = Date()
            self.lastSpokenTime = Date()
            self.lastResultReceivedTime = Date()
            self.lastVoiceEnergyDetectedTime = .distantPast
            self.continuousVoiceFramesCount = 0
            self.currentUtteranceStartSeconds = 0.0
            self.committedCharCountInCurrentTask = 0
            self.latestFullTaskTranscription = ""
            self.currentProvisionalText = ""
            self.lastCommittedUtteranceText = ""
            self.hotwords = hotwords
            self.systemAudioRingBuffer.removeAll(keepingCapacity: true)
            self.preRollPCMChunks.removeAll(keepingCapacity: true)
            self.isMicrophoneActive = false

            // 1. 録音先 WAV ファイル作成
            let recordingSettings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ]
            self.audioFile = try? AVAudioFile(forWriting: destinationWAVURL, settings: recordingSettings)

            // 2. 音声認識セッション初期化（TCC安全環境のみ）
            if Self.canSafelyUseSpeechRecognizerTCC {
                do {
                    try self.startNewSpeechRecognitionTaskLocked(replayPreRoll: false)
                } catch {
                    startError = error
                }
            }

            // 3. マイクキャプチャ開始
            if source == .microphone || source == .microphoneAndSystem {
                do {
                    try self.setupMicrophoneCaptureLocked()
                    self.isMicrophoneActive = true
                } catch {
                    self.isMicrophoneActive = false
                    self.onError?("マイク入力の開始に失敗しました: \(error.localizedDescription)")
                }
            }

            // 4. システム音声キャプチャ開始
            if source == .systemAudio || source == .microphoneAndSystem {
                self.setupSystemAudioCaptureAsync()
            }

            self.isRunningInternal = true
            self.startSilenceWatchdogLocked()
        }

        if let startError {
            throw startError
        }
    }

    public func stop() {
        stateQueue.sync {
            guard self.isRunningInternal else { return }
            self.isRunningInternal = false
            self.isMicrophoneActive = false

            self.stopSilenceWatchdogLocked()

            // 世代IDを進めて以降の非同期コールバックを完全遮断
            self.currentTaskGeneration &+= 1

            // 残っている未確定発話があれば確定コミット
            self.commitPendingUtteranceSliceLocked()

            // マイク停止
            if let engine = self.audioEngine, engine.isRunning {
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
            }
            self.audioEngine = nil
            self.audioFile = nil
            self.systemAudioRingBuffer.removeAll()
            self.preRollPCMChunks.removeAll()

            // システム音声ストリーム停止
            if let stream = self.systemAudioStream {
                Task {
                    try? await stream.stopCapture()
                }
                self.systemAudioStream = nil
            }

            // 認識タスク終了
            self.recognitionRequest?.endAudio()
            self.recognitionTask?.cancel()
            self.recognitionTask = nil
            self.recognitionRequest = nil

            self.onLevelMeterUpdate?(0.0)
            self.onProvisionalTextUpdate?("")
        }
    }

    // MARK: - オーディオ供給共通処理

    private func feedAudioSamplesToRecognizerLocked(_ samples16k: [Float]) {
        let rmsLevel = Self.calculateRMSLevel(samples: samples16k)
        self.onLevelMeterUpdate?(rmsLevel)

        if rmsLevel > 0.026 {
            self.lastVoiceEnergyDetectedTime = Date()
            self.continuousVoiceFramesCount += 1
        } else {
            self.continuousVoiceFramesCount = max(0, self.continuousVoiceFramesCount - 1)
        }

        guard let pcmBuffer = Self.makePCMBuffer(from: samples16k, format: self.commonAudioFormat) else { return }

        // プリロールバッファに保持（タスク再接続時の頭切れ防止）
        self.preRollPCMChunks.append(pcmBuffer)
        if self.preRollPCMChunks.count > self.maxPreRollChunks {
            self.preRollPCMChunks.removeFirst(self.preRollPCMChunks.count - self.maxPreRollChunks)
        }

        self.recognitionRequest?.append(pcmBuffer)
        try? self.audioFile?.write(from: pcmBuffer)
    }

    // MARK: - マイクキャプチャ (AVAudioEngine)

    private func setupMicrophoneCaptureLocked() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let nativeFormat = inputNode.inputFormat(forBus: 0)

        guard nativeFormat.sampleRate > 0 && nativeFormat.channelCount > 0 else {
            throw NSError(domain: "LiveAudioStreamEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "有効なマイク入力デバイスが見つかりません"])
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            guard let self else { return }

            let micSamples16k = Self.extractMono16kHzSamples(from: buffer)
            guard !micSamples16k.isEmpty else { return }

            self.stateQueue.async {
                guard self.isRunningInternal else { return }

                var mixedSamples = micSamples16k
                if self.activeSource == .microphoneAndSystem && !self.systemAudioRingBuffer.isEmpty {
                    let count = min(mixedSamples.count, self.systemAudioRingBuffer.count)
                    for i in 0..<count {
                        let sum = mixedSamples[i] + self.systemAudioRingBuffer[i]
                        mixedSamples[i] = max(-1.0, min(1.0, sum))
                    }
                    self.systemAudioRingBuffer.removeFirst(count)
                }

                self.feedAudioSamplesToRecognizerLocked(mixedSamples)
            }
        }

        do {
            try engine.start()
            self.audioEngine = engine
        } catch {
            inputNode.removeTap(onBus: 0)
            throw error
        }
    }

    // MARK: - システム音声キャプチャ (ScreenCaptureKit)

    private func setupSystemAudioCaptureAsync() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard let display = content.displays.first else {
                    self.onError?("システム音声: ディスプレイが見つかりません")
                    return
                }

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.capturesAudio = true
                config.excludesCurrentProcessAudio = true
                config.sampleRate = 48000
                config.channelCount = 2

                let stream = SCStream(filter: filter, configuration: config, delegate: self)
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.mnemosift.scaudio"))
                try await stream.startCapture()

                self.stateQueue.sync {
                    self.systemAudioStream = stream
                }
            } catch {
                self.onError?("システム音声の取得に失敗しました（システム設定 > プライバシーとセキュリティ > 画面収録 を確認してください）: \(error.localizedDescription)")
            }
        }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        let sysSamples16k = Self.extractMono16kHzSamples(from: sampleBuffer)
        guard !sysSamples16k.isEmpty else { return }

        stateQueue.async { [weak self] in
            guard let self, self.isRunningInternal else { return }

            if self.activeSource == .microphoneAndSystem && self.isMicrophoneActive {
                self.systemAudioRingBuffer.append(contentsOf: sysSamples16k)
                if self.systemAudioRingBuffer.count > self.maxRingBufferSamples {
                    let overflow = self.systemAudioRingBuffer.count - self.maxRingBufferSamples
                    self.systemAudioRingBuffer.removeFirst(overflow)
                }
            } else {
                self.feedAudioSamplesToRecognizerLocked(sysSamples16k)
            }
        }
    }

    // MARK: - SFSpeechRecognizer 連続認識 & 自動再起動エンジン

    private func startNewSpeechRecognitionTaskLocked(replayPreRoll: Bool) throws {
        guard Self.canSafelyUseSpeechRecognizerTCC else { return }
        guard let recognizer = speechRecognizer else {
            throw NSError(domain: "LiveAudioStreamEngine", code: 4, userInfo: [NSLocalizedDescriptionKey: "日本語の音声認識が利用できません"])
        }

        // 1. 世代IDを先に進めて、旧タスクからの endAudio/cancel 時の遅延コールバックを 100% 遮断する
        self.currentTaskGeneration &+= 1
        let expectedGeneration = self.currentTaskGeneration

        let oldRequest = self.recognitionRequest
        let oldTask = self.recognitionTask
        self.recognitionRequest = nil
        self.recognitionTask = nil

        oldRequest?.endAudio()
        oldTask?.cancel()

        self.committedCharCountInCurrentTask = 0
        self.latestFullTaskTranscription = ""
        self.currentProvisionalText = ""
        let now = Date()
        self.taskStartTime = now
        self.lastResultReceivedTime = now

        // 2. 新しい認識リクエストを構築（.dictation ヒントで長文・連続発話モードを指定）
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if useOnDeviceRecognition && recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        } else {
            request.requiresOnDeviceRecognition = false
        }
        if !hotwords.isEmpty {
            request.contextualStrings = Array(hotwords.prefix(50))
        }

        // プリロールバッファがあれば新しいリクエストに流し込んで発話頭切れを防ぐ
        if replayPreRoll {
            for chunk in self.preRollPCMChunks.suffix(8) {
                request.append(chunk)
            }
        }

        self.recognitionRequest = request
        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            self.stateQueue.async {
                // 旧世代タスクからのコールバックは完全に破棄（これで重複コミットと状態破壊を100%防止）
                guard self.isRunningInternal, self.currentTaskGeneration == expectedGeneration else { return }

                if let result {
                    self.lastResultReceivedTime = Date()
                    let fullText = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.handleUpdatedTranscriptionLocked(fullText: fullText, isFinal: result.isFinal)
                }

                if error != nil {
                    if self.useOnDeviceRecognition {
                        self.useOnDeviceRecognition = false
                    }
                    // タスクがエラーまたは無音タイムアウトで閉じた場合、未確定分をコミットして即座に新タスクへ再接続
                    self.commitPendingUtteranceSliceLocked()
                    try? self.startNewSpeechRecognitionTaskLocked(replayPreRoll: true)
                }
            }
        }
    }

    private func handleUpdatedTranscriptionLocked(fullText: String, isFinal: Bool) {
        if fullText.count < self.committedCharCountInCurrentTask {
            self.committedCharCountInCurrentTask = min(self.committedCharCountInCurrentTask, fullText.count)
        }

        self.latestFullTaskTranscription = fullText

        // 1. 現在の未確定文字列を抽出
        var uncommittedSlice: String
        if self.committedCharCountInCurrentTask <= fullText.count {
            let startIdx = fullText.index(fullText.startIndex, offsetBy: self.committedCharCountInCurrentTask)
            uncommittedSlice = String(fullText[startIdx...])
        } else {
            uncommittedSlice = ""
        }

        // 2. 未確定テキストが一定長になり、文中に自然な分割点（「。」や文末表現）がある場合、先行する文をインライン確定コミット
        while let splitIdx = Self.findNaturalSplitPoint(in: uncommittedSlice, minLength: 24, maxLength: 65) {
            let rawSentence = String(uncommittedSlice[..<splitIdx])
            let sentenceToCommit = rawSentence.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentenceToCommit.isEmpty else { break }

            let consumedCharCount = uncommittedSlice.distance(from: uncommittedSlice.startIndex, to: splitIdx)
            self.committedCharCountInCurrentTask = min(fullText.count, self.committedCharCountInCurrentTask + consumedCharCount)

            let formattedSentence = Self.formatJapanesePunctuation(sentenceToCommit)
            if formattedSentence != self.lastCommittedUtteranceText {
                self.lastCommittedUtteranceText = formattedSentence
                let nowSeconds = Date().timeIntervalSince(self.sessionStartTime)
                let startSec = self.currentUtteranceStartSeconds
                let endSec = max(startSec + 0.8, nowSeconds)
                self.currentUtteranceStartSeconds = endSec
                self.onFinalizedUtterance?(formattedSentence, startSec, endSec)
            }

            uncommittedSlice = String(uncommittedSlice[splitIdx...])
            self.currentUtteranceStartSeconds = Date().timeIntervalSince(self.sessionStartTime)
        }

        // 3. 残りの未確定スライスを暫定テキストとして画面に反映
        let trimmedProvisional = uncommittedSlice.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedProvisional.isEmpty && trimmedProvisional != self.currentProvisionalText {
            if self.currentProvisionalText.isEmpty {
                self.currentUtteranceStartSeconds = Date().timeIntervalSince(self.sessionStartTime)
            }
            self.lastSpokenTime = Date()
            self.currentProvisionalText = trimmedProvisional
            let formattedProvisional = Self.formatJapanesePunctuation(trimmedProvisional)
            self.onProvisionalTextUpdate?(formattedProvisional)
        } else if trimmedProvisional.isEmpty && !self.currentProvisionalText.isEmpty {
            self.currentProvisionalText = ""
            self.onProvisionalTextUpdate?("")
        }

        // Apple 側が1セッション終了 (isFinal) を返した場合、確定させてから即座に新タスクをプリロール付きで起動
        if isFinal {
            self.commitPendingUtteranceSliceLocked()
            try? self.startNewSpeechRecognitionTaskLocked(replayPreRoll: true)
        }
    }

    private func startSilenceWatchdogLocked() {
        stopSilenceWatchdogLocked()

        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunningInternal else { return }

            let now = Date()
            let timeSinceLastSpoken = now.timeIntervalSince(self.lastSpokenTime)
            let timeSinceLastVoice = now.timeIntervalSince(self.lastVoiceEnergyDetectedTime)
            let isVoiceActive = timeSinceLastVoice < 0.45

            if !self.currentProvisionalText.isEmpty {
                let hasEnding = Self.hasSentenceEnding(self.currentProvisionalText)
                let hasContinuation = Self.hasContinuationEnding(self.currentProvisionalText)
                let textLength = self.currentProvisionalText.count

                // 確定条件:
                // 1. 文末表現（〜です、〜ます、句点等）がある場合: テキスト更新が 0.45秒 止まったら即座に確定
                let isSentenceFinished = hasEnding && timeSinceLastSpoken >= 0.45

                // 2. 接続助詞（〜ですが、〜ので等）の場合: 息継ぎ待ちとして 1.3秒 待機
                let isContinuationPause = hasContinuation && !isVoiceActive && timeSinceLastSpoken >= 1.3

                // 3. 通常の途中語句の場合: テキスト更新停止 0.8秒 で確定
                let isNormalPause = !hasEnding && !hasContinuation && timeSinceLastSpoken >= 0.8 && !isVoiceActive

                // 4. 文字数が多くなった場合（50文字以上）: テキスト更新停止 0.35秒 で確定
                let isLongTextBreak = textLength >= 50 && timeSinceLastSpoken >= 0.35

                // 5. セーフティ上限（80文字以上）: 0.25秒止まったら即座に分割確定
                let isSafetyLimit = textLength >= 80 && timeSinceLastSpoken >= 0.25

                if isSentenceFinished || isContinuationPause || isNormalPause || isLongTextBreak || isSafetyLimit {
                    // 発話を確定コミット（タスクは再起動せず継続）
                    self.commitPendingUtteranceSliceLocked()

                    // アイドル時の定期タスクローテーション
                    let taskAge = now.timeIntervalSince(self.taskStartTime)
                    if taskAge >= 40.0 || self.latestFullTaskTranscription.count >= 250 {
                        try? self.startNewSpeechRecognitionTaskLocked(replayPreRoll: true)
                    }
                }
            } else if Self.canSafelyUseSpeechRecognizerTCC {
                // 未確定テキストが空のアイドル状態
                let taskState = self.recognitionTask?.state
                let taskAge = now.timeIntervalSince(self.taskStartTime)
                let timeSinceLastResult = now.timeIntervalSince(self.lastResultReceivedTime)
                let hasRecentVoice = timeSinceLastVoice < 0.6 && self.continuousVoiceFramesCount >= 6

                if self.recognitionRequest == nil || taskState == .completed || taskState == .canceling {
                    try? self.startNewSpeechRecognitionTaskLocked(replayPreRoll: true)
                } else if hasRecentVoice && timeSinceLastResult >= 3.5 && taskAge >= 3.5 {
                    // 音声が継続しているのに認識結果が返ってこないセッション詰まりの救済
                    try? self.startNewSpeechRecognitionTaskLocked(replayPreRoll: true)
                } else if taskAge >= 45.0 && !isVoiceActive && timeSinceLastVoice >= 1.0 {
                    // 45秒経過かつ直近1.0秒以上完全無音なら、誰も話していないアイドル時に安全に新タスクへローテーション
                    try? self.startNewSpeechRecognitionTaskLocked(replayPreRoll: true)
                }
            }
        }
        timer.resume()
        self.silenceWatchdogTimer = timer
    }

    private func stopSilenceWatchdogLocked() {
        silenceWatchdogTimer?.cancel()
        silenceWatchdogTimer = nil
    }

    /// 現在の未確定テキストスライスを1つの発話セグメントとして確定させる（重複排除付き）
    private func commitPendingUtteranceSliceLocked() {
        let rawSlice = self.currentProvisionalText.trimmingCharacters(in: .whitespacesAndNewlines)
        self.committedCharCountInCurrentTask = self.latestFullTaskTranscription.count
        self.currentProvisionalText = ""
        self.onProvisionalTextUpdate?("")

        guard !rawSlice.isEmpty else { return }

        let formattedText = Self.formatJapanesePunctuation(rawSlice)
        // 直前の確定発話と同一内容の重複コミットを確実にブロック
        guard formattedText != self.lastCommittedUtteranceText else { return }
        self.lastCommittedUtteranceText = formattedText

        let nowSeconds = Date().timeIntervalSince(self.sessionStartTime)
        let startSec = self.currentUtteranceStartSeconds
        let endSec = max(startSec + 0.8, nowSeconds)
        self.currentUtteranceStartSeconds = endSec

        self.onFinalizedUtterance?(formattedText, startSec, endSec)
    }

    // MARK: - 日本語文末・接続助詞判定と適応型無音閾値・インライン分割

    public static let commonSentenceEndings: [String] = [
        "ようこそ", "ございます", "ございました", "お願いします", "いたしました",
        "いきましょう", "きましょう", "ご覧ください", "確認ください", "試しください",
        "お届けしています", "お届けします", "紹介しています", "解説します",
        "でしょうか", "ますでしょうか", "ました", "でした", "ません",
        "思います", "思われます", "おります", "なります", "なっています", "なっております",
        "ものです", "ことです", "わけです", "がちです",
        "ます", "です", "しょう", "さい"
    ]

    public static let commonContinuationParticles: [String] = [
        "が", "けど", "けれど", "ので", "から", "し", "と", "て", "で",
        "たり", "ながら", "けれども", "ものの", "ところで", "あと", "また", "ね", "よ", "な", "か"
    ]

    /// 与えられたテキスト内で、自然に分割可能な位置（文末表現、句点「。」、または長文時の読点「、」・助詞）を探索する
    public static func findNaturalSplitPoint(in text: String, minLength: Int = 24, maxLength: Int = 65) -> String.Index? {
        guard text.count >= minLength else { return nil }

        let minIdx = text.index(text.startIndex, offsetBy: minLength)

        // 1. 最優先: minLength 以降にある句点「。」の直後
        if let dotRange = text[minIdx...].range(of: "。") {
            let afterDot = dotRange.upperBound
            if text.distance(from: afterDot, to: text.endIndex) >= 4 {
                return afterDot
            }
        }

        // 2. 文末表現（〜ます、〜です、〜でした、〜思います など）の直後
        let searchEnd = text.count > maxLength ? text.index(text.startIndex, offsetBy: maxLength) : text.endIndex
        if minIdx < searchEnd {
            let searchSub = text[minIdx..<searchEnd]
            for ending in commonSentenceEndings {
                if let range = searchSub.range(of: ending) {
                    var splitIdx = range.upperBound
                    if splitIdx < text.endIndex {
                        let nextChar = text[splitIdx]
                        if nextChar == "。" || nextChar == "、" || nextChar == " " {
                            splitIdx = text.index(after: splitIdx)
                        }
                    }
                    if text.distance(from: splitIdx, to: text.endIndex) >= 4 {
                        return splitIdx
                    }
                }
            }
        }

        // 3. maxLength（65文字程度）を超えている場合、読点「、」や助詞の切れ目でも分割
        if text.count >= maxLength {
            if let commaRange = text[minIdx...].range(of: "、") {
                let afterComma = commaRange.upperBound
                if text.distance(from: afterComma, to: text.endIndex) >= 4 {
                    return afterComma
                }
            }
            let splitParticles = ["ですが", "だけど", "けれど", "ので", "から", "また", "そして", "が", "けど", "し", "て", "で"]
            for part in splitParticles {
                if let range = text[minIdx...].range(of: part) {
                    let afterPart = range.upperBound
                    if text.distance(from: afterPart, to: text.endIndex) >= 4 {
                        return afterPart
                    }
                }
            }
        }

        return nil
    }

    /// 発話末尾が一文の完結（文末）を示しているかどうかを判定
    public static func hasSentenceEnding(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasSuffix("。") || trimmed.hasSuffix("？") || trimmed.hasSuffix("！") {
            return true
        }
        return commonSentenceEndings.contains { trimmed.hasSuffix($0) }
    }

    /// 発話末尾が接続助詞などで「文がまだ継続している」可能性が高いかどうかを判定
    public static func hasContinuationEnding(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return commonContinuationParticles.contains { trimmed.hasSuffix($0) }
    }

    /// テキストの文脈に応じて、自然な息継ぎや言い淀みによる途中分断を防ぐ適応型無音待機時間（秒）を算出
    private func adaptiveSilenceThreshold(for text: String) -> Double {
        if Self.hasSentenceEnding(text) {
            return 0.45
        } else if Self.hasContinuationEnding(text) {
            return 1.3
        } else {
            return 0.8
        }
    }

    /// 句読点のない連続音声認識テキストに自然な句読点（。・、）を補完する
    public static func formatJapanesePunctuation(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        if result.contains("。") {
            return result
        }

        let sentenceEndings = commonSentenceEndings
        let continuationParticles = commonContinuationParticles

        for ending in sentenceEndings {
            var searchRange = result.startIndex..<result.endIndex
            while let range = result.range(of: ending, options: [], range: searchRange) {
                let afterIdx = range.upperBound
                if afterIdx == result.endIndex {
                    break
                }
                let nextChar = String(result[afterIdx])
                if nextChar == "。" || nextChar == "、" || nextChar == " " {
                    searchRange = afterIdx..<result.endIndex
                    continue
                }
                let remaining = String(result[afterIdx...])
                let isContinuation = continuationParticles.contains { remaining.hasPrefix($0) }
                if !isContinuation {
                    result.insert("。", at: afterIdx)
                    let nextStart = result.index(after: afterIdx)
                    searchRange = nextStart..<result.endIndex
                } else {
                    searchRange = afterIdx..<result.endIndex
                }
            }
        }

        let connectors = ["それでは", "また", "そして", "しかし", "ただ", "そこで", "ちなみに", "例えば"]
        for conn in connectors {
            result = result.replacingOccurrences(of: "。\(conn)", with: "。\(conn)、")
                .replacingOccurrences(of: "、、", with: "、")
        }

        if !result.hasSuffix("。") && !result.hasSuffix("？") && !result.hasSuffix("！") {
            result += "。"
        }
        return result
    }

    // MARK: - ステートレス 16kHz モノラル変換 & RMS 計算

    private static func calculateRMSLevel(samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0.0 }
        var rms: Float = 0.0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        return min(1.0, max(0.0, Double(rms) * 6.0))
    }

    private static func makePCMBuffer(from samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let dst = pcmBuffer.floatChannelData?[0] else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            if let base = ptr.baseAddress {
                memcpy(dst, base, samples.count * MemoryLayout<Float>.size)
            }
        }
        return pcmBuffer
    }

    private static func extractMono16kHzSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frameLength = Int(buffer.frameLength)
        let sampleRate = buffer.format.sampleRate
        let channels = Int(buffer.format.channelCount)
        guard frameLength > 0, sampleRate > 0, channels > 0 else { return [] }

        var monoSource = [Float](repeating: 0, count: frameLength)
        if let floatData = buffer.floatChannelData {
            if channels >= 2 && !buffer.format.isInterleaved {
                let ch0 = floatData[0]
                let ch1 = floatData[1]
                for i in 0..<frameLength {
                    monoSource[i] = (ch0[i] + ch1[i]) * 0.5
                }
            } else if buffer.format.isInterleaved && channels >= 2 {
                let ptr = floatData[0]
                for i in 0..<frameLength {
                    monoSource[i] = (ptr[i * channels] + ptr[i * channels + 1]) * 0.5
                }
            } else {
                let ch0 = floatData[0]
                for i in 0..<frameLength {
                    monoSource[i] = ch0[i]
                }
            }
        } else if let int16Data = buffer.int16ChannelData {
            let ch0 = int16Data[0]
            for i in 0..<frameLength {
                monoSource[i] = Float(ch0[i]) / 32768.0
            }
        } else {
            return []
        }

        return resampleTo16kHz(samples: monoSource, sourceSampleRate: sampleRate)
    }

    private static func extractMono16kHzSamples(from sampleBuffer: CMSampleBuffer) -> [Float] {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return []
        }
        let asbd = asbdPtr.pointee
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0, asbd.mSampleRate > 0 else { return [] }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return [] }
        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == noErr, let dataPointer, totalLength > 0 else { return [] }

        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let channels = max(1, Int(asbd.mChannelsPerFrame))

        var monoSource = [Float](repeating: 0, count: numSamples)

        if isFloat {
            let totalFloats = totalLength / MemoryLayout<Float>.size
            dataPointer.withMemoryRebound(to: Float.self, capacity: totalFloats) { floatPtr in
                if isNonInterleaved && channels >= 2 && totalFloats >= numSamples * 2 {
                    for i in 0..<numSamples {
                        monoSource[i] = (floatPtr[i] + floatPtr[numSamples + i]) * 0.5
                    }
                } else if !isNonInterleaved && channels >= 2 && totalFloats >= numSamples * channels {
                    for i in 0..<numSamples {
                        monoSource[i] = (floatPtr[i * channels] + floatPtr[i * channels + 1]) * 0.5
                    }
                } else {
                    let count = min(numSamples, totalFloats)
                    for i in 0..<count {
                        monoSource[i] = floatPtr[i]
                    }
                }
            }
        } else if asbd.mBitsPerChannel == 16 {
            let totalShorts = totalLength / MemoryLayout<Int16>.size
            dataPointer.withMemoryRebound(to: Int16.self, capacity: totalShorts) { shortPtr in
                let count = min(numSamples, totalShorts / (isNonInterleaved ? 1 : channels))
                for i in 0..<count {
                    let idx = isNonInterleaved ? i : (i * channels)
                    monoSource[i] = Float(shortPtr[idx]) / 32768.0
                }
            }
        } else {
            return []
        }

        return resampleTo16kHz(samples: monoSource, sourceSampleRate: asbd.mSampleRate)
    }

    private static func resampleTo16kHz(samples: [Float], sourceSampleRate: Double) -> [Float] {
        guard !samples.isEmpty else { return [] }
        if abs(sourceSampleRate - 16000.0) < 1.0 {
            return samples
        }
        let ratio = sourceSampleRate / 16000.0
        let outCount = Int(Double(samples.count) / ratio)
        guard outCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outCount)
        let maxIdx = samples.count - 1
        for i in 0..<outCount {
            let srcPos = Double(i) * ratio
            let idx0 = min(maxIdx, Int(srcPos))
            let idx1 = min(maxIdx, idx0 + 1)
            let frac = Float(srcPos - Double(idx0))
            output[i] = samples[idx0] * (1.0 - frac) + samples[idx1] * frac
        }
        return output
    }
}
