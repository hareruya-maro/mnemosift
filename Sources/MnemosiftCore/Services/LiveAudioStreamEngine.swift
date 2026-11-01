import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import Speech
import ScreenCaptureKit
import Accelerate

/// リアルタイム音声キャプチャ（マイク ＆ ScreenCaptureKit システム音声）と
/// オンデバイス音声認識（SFSpeechRecognizer）を実行するネイティブストリーミングエンジン
public final class LiveAudioStreamEngine: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "com.mnemosift.livestream.queue")

    // 音声認識
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var hotwords: [String] = []

    // 共通オーディオフォーマット (16kHz モノラル Float32)
    private let commonAudioFormat: AVAudioFormat

    // マイクキャプチャ
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var micConverter: AVAudioConverter?

    // システム音声キャプチャ (ScreenCaptureKit)
    private var systemAudioStream: SCStream?
    private var sysConverter: AVAudioConverter?

    // 状態管理
    private var isRunningInternal: Bool = false
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

    // MARK: - 権限チェック・要求

    public static func requestPermissions() async -> (mic: Bool, speech: Bool) {
        let micStatus = await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
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

            self.sessionStartTime = Date()
            self.lastSpokenTime = Date()
            self.lastFinalizedTimeSeconds = 0.0
            self.currentProvisionalText = ""
            self.hotwords = hotwords

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

            // 2. 音声認識セッション初期化
            do {
                try self.setupSpeechRecognitionLocked(hotwords: hotwords)
            } catch {
                startError = error
                return
            }

            // 3. マイクキャプチャ開始
            if source == .microphone || source == .microphoneAndSystem {
                do {
                    try self.setupMicrophoneCaptureLocked()
                } catch {
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

            self.stopSilenceWatchdogLocked()

            // マイク停止
            if let engine = self.audioEngine, engine.isRunning {
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
            }
            self.audioEngine = nil
            self.audioFile = nil
            self.micConverter = nil

            // システム音声ストリーム停止
            if let stream = self.systemAudioStream {
                Task {
                    try? await stream.stopCapture()
                }
                self.systemAudioStream = nil
                self.sysConverter = nil
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

        let targetFormat = self.commonAudioFormat

        inputNode.removeTap(onBus: 0)
        // format に nil を渡すことで、ノードの内部バス形式と合致させ、CoreAudio の format mismatch 例外を防止する
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            guard let self, self.stateQueue.sync(execute: { self.isRunningInternal }) else { return }

            // 1. RMS レベルメーター
            let rmsLevel = Self.calculateRMSLevel(buffer: buffer)
            self.onLevelMeterUpdate?(rmsLevel)

            // 2. 16kHz モノラル Float32 に変換して供給
            let sourceFormat = buffer.format
            guard sourceFormat.sampleRate > 0 else { return }

            let converter: AVAudioConverter?
            if let existing = self.micConverter, existing.inputFormat == sourceFormat {
                converter = existing
            } else {
                converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
                self.micConverter = converter
            }

            guard let converter else { return }
            let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * (16000.0 / sourceFormat.sampleRate))
            if frameCapacity > 0, let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) {
                var error: NSError?
                var allConsumed = false
                converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    if !allConsumed {
                        allConsumed = true
                        outStatus.pointee = .haveData
                        return buffer
                    } else {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                }

                if error == nil && convertedBuffer.frameLength > 0 {
                    self.stateQueue.async {
                        self.recognitionRequest?.append(convertedBuffer)
                        try? self.audioFile?.write(from: convertedBuffer)
                    }
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
                config.excludesCurrentProcessAudio = true // 自アプリの音響ループ防止
                config.sampleRate = 16000
                config.channelCount = 1

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
        guard type == .audio, stateQueue.sync(execute: { self.isRunningInternal }) else { return }

        if let pcmBuffer = Self.createPCMBuffer(from: sampleBuffer, targetFormat: commonAudioFormat) {
            let level = Self.calculateRMSLevel(buffer: pcmBuffer)
            if level > 0.05 {
                onLevelMeterUpdate?(level)
            }
            stateQueue.async {
                self.recognitionRequest?.append(pcmBuffer)
                try? self.audioFile?.write(from: pcmBuffer)
            }
        }
    }

    // MARK: - SFSpeechRecognizer セットアップ & 発話監視

    private func setupSpeechRecognitionLocked(hotwords: [String]) throws {
        guard let recognizer = speechRecognizer else {
            throw NSError(domain: "LiveAudioStreamEngine", code: 4, userInfo: [NSLocalizedDescriptionKey: "日本語の音声認識が利用できません"])
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
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
                // 209 (kAFAssistantErrorDomain Code=209), 216 (Task cancelled) 以外は再接続
                if nsErr.code != 209 && nsErr.code != 216 {
                    self.stateQueue.sync {
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

    // MARK: - ユーティリティ (RMS計算 & バッファ変換)

    private static func calculateRMSLevel(buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData else { return 0.0 }
        let channelCount = Int(buffer.format.channelCount)
        let length = vDSP_Length(buffer.frameLength)
        guard length > 0 else { return 0.0 }

        var rms: Float = 0.0
        vDSP_rmsqv(channelData[0], 1, &rms, length)
        if channelCount > 1 {
            var rms2: Float = 0.0
            vDSP_rmsqv(channelData[1], 1, &rms2, length)
            rms = (rms + rms2) / 2.0
        }
        let level = min(1.0, max(0.0, Double(rms) * 5.0))
        return level
    }

    private static func createPCMBuffer(from sampleBuffer: CMSampleBuffer, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let audioStreamDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }

        guard let sourceFormat = AVAudioFormat(streamDescription: audioStreamDesc) else { return nil }
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        guard numSamples > 0 else { return nil }

        guard let sourcePCMBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(numSamples)) else {
            return nil
        }
        sourcePCMBuffer.frameLength = AVAudioFrameCount(numSamples)

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
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
        guard status == noErr, let dataPointer else { return nil }

        if let destFloat = sourcePCMBuffer.floatChannelData?[0] {
            memcpy(destFloat, dataPointer, min(totalLength, Int(sourcePCMBuffer.frameLength) * MemoryLayout<Float>.size))
        } else if let destInt = sourcePCMBuffer.int16ChannelData?[0] {
            memcpy(destInt, dataPointer, min(totalLength, Int(sourcePCMBuffer.frameLength) * MemoryLayout<Int16>.size))
        }

        if sourceFormat == targetFormat {
            return sourcePCMBuffer
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            return sourcePCMBuffer
        }

        let targetCapacity = AVAudioFrameCount(Double(numSamples) * (targetFormat.sampleRate / sourceFormat.sampleRate))
        guard targetCapacity > 0, let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetCapacity) else {
            return sourcePCMBuffer
        }

        var error: NSError?
        var consumed = false
        converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
            if !consumed {
                consumed = true
                outStatus.pointee = .haveData
                return sourcePCMBuffer
            } else {
                outStatus.pointee = .noDataNow
                return nil
            }
        }

        return error == nil ? convertedBuffer : sourcePCMBuffer
    }
}
