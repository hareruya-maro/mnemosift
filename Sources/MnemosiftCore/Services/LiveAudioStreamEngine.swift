import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import Speech
import ScreenCaptureKit
import Accelerate

/// リアルタイム音声キャプチャ（マイク ＆ ScreenCaptureKit システム音声）と
/// 音声認識（SFSpeechRecognizer）を実行するネイティブストリーミングエンジン
public final class LiveAudioStreamEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "com.mnemosift.livestream.queue")

    // 音声認識
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hotwords: [String] = []
    private var useOnDeviceRecognition: Bool = false

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
    private var currentProvisionalText: String = ""
    private var silenceWatchdogTimer: DispatchSourceTimer?

    // コールバック
    public var onLevelMeterUpdate: (@Sendable (Double) -> Void)?
    public var onProvisionalTextUpdate: (@Sendable (String) -> Void)?
    public var onFinalizedUtterance: (@Sendable (String, Double, Double) -> Void)?
    public var onError: (@Sendable (String) -> Void)?

    private var sessionStartTime: Date = Date()
    private var lastFinalizedTimeSeconds: Double = 0.0

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

    /// macOS の TCC は、SFSpeechRecognizer を .app バンドル（LaunchServices 経由）以外から呼ぶと
    /// __TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__ でプロセスを強制終了させるため、実行環境を判定する
    public static var canSafelyUseSpeechRecognizerTCC: Bool {
        if ProcessInfo.processInfo.environment["MNEMOSIFT_LAUNCHED_AS_APP"] == "1" {
            return true
        }
        let bundlePath = Bundle.main.bundlePath
        let execPath = ProcessInfo.processInfo.arguments.first ?? ""
        // MnemosiftTests などのテストランナー実行時は false にする
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

        // TCC Privacy Violation クラッシュ防止ガード
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

    public func start(
        source: AudioSourceType,
        destinationWAVURL: URL,
        hotwords: [String] = []
    ) throws {
        var startError: Error?

        stateQueue.sync {
            guard !self.isRunningInternal else { return }

            self.activeSource = source
            self.sessionStartTime = Date()
            self.lastSpokenTime = Date()
            self.lastFinalizedTimeSeconds = 0.0
            self.currentProvisionalText = ""
            self.hotwords = hotwords
            self.systemAudioRingBuffer.removeAll(keepingCapacity: true)
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
                    try self.setupSpeechRecognitionLocked(hotwords: hotwords)
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

            // マイク停止
            if let engine = self.audioEngine, engine.isRunning {
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
            }
            self.audioEngine = nil
            self.audioFile = nil
            self.systemAudioRingBuffer.removeAll()

            // システム音声ストリーム停止
            if let stream = self.systemAudioStream {
                Task {
                    try? await stream.stopCapture()
                }
                self.systemAudioStream = nil
            }

            // 最後の発話を確定して認識タスクを終了
            self.finalizeCurrentSpeechLocked(forceCommit: true)
            self.recognitionRequest?.endAudio()
            self.recognitionTask?.cancel()
            self.recognitionTask = nil
            self.recognitionRequest = nil

            self.onLevelMeterUpdate?(0.0)
            self.onProvisionalTextUpdate?("")
        }
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

                // システム音声とのミキシング（microphoneAndSystem の場合、1本の連続ストリームに合成）
                var mixedSamples = micSamples16k
                if self.activeSource == .microphoneAndSystem && !self.systemAudioRingBuffer.isEmpty {
                    let count = min(mixedSamples.count, self.systemAudioRingBuffer.count)
                    for i in 0..<count {
                        let sum = mixedSamples[i] + self.systemAudioRingBuffer[i]
                        mixedSamples[i] = max(-1.0, min(1.0, sum))
                    }
                    self.systemAudioRingBuffer.removeFirst(count)
                }

                let rmsLevel = Self.calculateRMSLevel(samples: mixedSamples)
                self.onLevelMeterUpdate?(rmsLevel)

                if let pcmBuffer = Self.makePCMBuffer(from: mixedSamples, format: self.commonAudioFormat) {
                    self.recognitionRequest?.append(pcmBuffer)
                    try? self.audioFile?.write(from: pcmBuffer)
                }
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
                // マイクストリーム側で1本のストリームとしてミキシング消費するためリングバッファへ追加
                self.systemAudioRingBuffer.append(contentsOf: sysSamples16k)
                if self.systemAudioRingBuffer.count > self.maxRingBufferSamples {
                    let overflow = self.systemAudioRingBuffer.count - self.maxRingBufferSamples
                    self.systemAudioRingBuffer.removeFirst(overflow)
                }
            } else {
                // システム音声のみモード（またはマイク非稼働時）は直接 SpeechRecognizer へ供給
                let level = Self.calculateRMSLevel(samples: sysSamples16k)
                self.onLevelMeterUpdate?(level)

                if let pcmBuffer = Self.makePCMBuffer(from: sysSamples16k, format: self.commonAudioFormat) {
                    self.recognitionRequest?.append(pcmBuffer)
                    try? self.audioFile?.write(from: pcmBuffer)
                }
            }
        }
    }

    // MARK: - SFSpeechRecognizer セットアップ & 発話監視

    private func setupSpeechRecognitionLocked(hotwords: [String]) throws {
        guard Self.canSafelyUseSpeechRecognizerTCC else { return }
        guard let recognizer = speechRecognizer else {
            throw NSError(domain: "LiveAudioStreamEngine", code: 4, userInfo: [NSLocalizedDescriptionKey: "日本語の音声認識が利用できません"])
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if useOnDeviceRecognition && recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        } else {
            request.requiresOnDeviceRecognition = false
        }
        if !hotwords.isEmpty {
            request.contextualStrings = Array(hotwords.prefix(50))
        }

        self.recognitionRequest = request
        self.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let transcription = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                if !transcription.isEmpty {
                    self.stateQueue.sync {
                        self.lastSpokenTime = Date()
                        self.currentProvisionalText = transcription
                    }
                    self.onProvisionalTextUpdate?(transcription)
                }

                if result.isFinal {
                    self.stateQueue.sync {
                        self.finalizeCurrentSpeechLocked(forceCommit: true)
                    }
                }
            }

            if let error {
                let nsErr = error as NSError
                // 209 / 216 (キャンセル) 以外のエラー時は自動再接続
                if nsErr.code != 209 && nsErr.code != 216 {
                    self.stateQueue.sync {
                        if self.useOnDeviceRecognition {
                            self.useOnDeviceRecognition = false
                        }
                        if self.isRunningInternal {
                            self.resetSpeechRequestLocked()
                        }
                    }
                }
            }
        }
    }

    private func startSilenceWatchdogLocked() {
        stopSilenceWatchdogLocked()

        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(400))
        timer.setEventHandler { [weak self] in
            guard let self, self.isRunningInternal else { return }

            let silenceDuration = Date().timeIntervalSince(self.lastSpokenTime)
            if silenceDuration >= 1.3 && !self.currentProvisionalText.isEmpty {
                self.finalizeCurrentSpeechLocked(forceCommit: false)
            }
        }
        timer.resume()
        self.silenceWatchdogTimer = timer
    }

    private func stopSilenceWatchdogLocked() {
        silenceWatchdogTimer?.cancel()
        silenceWatchdogTimer = nil
    }

    private func finalizeCurrentSpeechLocked(forceCommit: Bool) {
        let text = currentProvisionalText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let nowSeconds = Date().timeIntervalSince(sessionStartTime)
        let startSec = lastFinalizedTimeSeconds
        let endSec = max(startSec + 0.8, nowSeconds)
        self.lastFinalizedTimeSeconds = endSec

        self.currentProvisionalText = ""
        self.onProvisionalTextUpdate?("")
        self.onFinalizedUtterance?(text, startSec, endSec)

        if !forceCommit && isRunningInternal {
            resetSpeechRequestLocked()
        }
    }

    private func resetSpeechRequestLocked() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        try? setupSpeechRecognitionLocked(hotwords: self.hotwords)
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
