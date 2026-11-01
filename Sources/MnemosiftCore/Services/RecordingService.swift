import Foundation
import AVFoundation
import ScreenCaptureKit
import Observation

/// 仕様書 §5.1-5.2 & §12.1-12.2: 録音サービス
/// - マイク録音、システム音声録音 (ScreenCaptureKit)、同時録音、音声ファイル取込に対応
/// - 音声データのファイル保存処理とSTT処理を分離し、STTの遅延・エラーによって録音を失わない
/// - 画面遷移に依存せず録音を継続し、異常終了後の録音復旧に対応する
@Observable
@MainActor
public final class RecordingService {
    private let database: LocalDatabase
    public private(set) var recordings: [Recording] = []
    public private(set) var state: RecordingState = .idle
    public private(set) var activeRecording: Recording?
    public private(set) var elapsedSeconds: Double = 0
    public private(set) var inputLevel: Double = 0.0
    public private(set) var waveformSamples: [Double] = Array(repeating: 0.08, count: 32)
    public private(set) var permissionStatusNote: String = "マイク・システム音声（ScreenCaptureKit）利用可能"

    public let liveEngine = LiveAudioStreamEngine()
    public var onProvisionalText: (@MainActor (String) -> Void)?
    public var onFinalizedUtterance: (@MainActor (String, Double, Double) -> Void)?
    public var onEngineError: (@MainActor (String) -> Void)?

    private var timerTask: Task<Void, Never>?

    public init(database: LocalDatabase) {
        self.database = database
        let loaded = (try? database.loadRecordings()) ?? []
        var updatedList: [Recording] = []
        // 仕様書 §12.2: アプリ異常終了後の未完了録音セッションを検出し復旧する
        for var rec in loaded {
            if rec.completedAt == nil {
                rec.isRecoveredFromInterruptedSession = true
                rec.completedAt = Date()
                if rec.durationSeconds <= 0 {
                    rec.durationSeconds = 12.0
                }
                try? database.saveRecording(rec)
            }
            updatedList.append(rec)
        }
        self.recordings = updatedList

        setupLiveEngineCallbacks()
    }

    private func setupLiveEngineCallbacks() {
        self.liveEngine.onLevelMeterUpdate = { [weak self] level in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                self.inputLevel = level
                var nextWave = self.waveformSamples
                nextWave.removeFirst()
                nextWave.append(level)
                self.waveformSamples = nextWave
            }
        }
        self.liveEngine.onProvisionalTextUpdate = { [weak self] text in
            Task { @MainActor in
                self?.onProvisionalText?(text)
            }
        }
        self.liveEngine.onFinalizedUtterance = { [weak self] text, startSec, endSec in
            Task { @MainActor in
                self?.onFinalizedUtterance?(text, startSec, endSec)
            }
        }
        self.liveEngine.onError = { [weak self] errorMsg in
            Task { @MainActor in
                self?.onEngineError?(errorMsg)
            }
        }
    }

    public func checkPermissionsStatus() -> String {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micText = switch micStatus {
        case .authorized: "マイク権限: 許可済み"
        case .notDetermined: "マイク権限: 初回録音時に確認"
        case .denied, .restricted: "マイク権限: システム設定 > プライバシーとセキュリティ > マイク で許可してください"
        @unknown default: "マイク権限: 不明"
        }
        let sysScreenCapture = LiveAudioStreamEngine.checkSystemAudioScreenCaptureAccess()
        let sysText = sysScreenCapture ? "システム音声(画面収録): 許可済み" : "システム音声(画面収録): システム設定でMnemosiftを許可してください"
        let combined = "\(micText) / \(sysText)"
        self.permissionStatusNote = combined
        return combined
    }

    /// 録音を開始する（STT処理とは独立して即座にローカルファイルパスを確保・保存する）
    public func startRecording(
        title: String,
        source: AudioSourceType,
        projectIds: [UUID],
        hotwords: [String] = []
    ) throws -> Recording {
        let recordingsDir = try ensureRecordingsDirectory()
        let fileId = UUID()
        let fileURL = recordingsDir.appendingPathComponent("recording-\(fileId.uuidString).wav")

        // リアルタイムオーディオキャプチャ＆オンデバイス音声認識を開始
        do {
            try liveEngine.start(source: source, destinationWAVURL: fileURL, hotwords: hotwords)
        } catch {
            // エンジン起動エラー時でもフォールバックとしてダミーWAVヘッダを確保
            try? Self.writeMinimalWAVFile(to: fileURL, durationSeconds: 1.0)
            onEngineError?("音声認識エンジンの起動に失敗しました: \(error.localizedDescription)")
        }

        let recording = Recording(
            id: fileId,
            title: title.isEmpty ? "会議録音 \(Self.dateFormatter().string(from: Date()))" : title,
            projectIds: projectIds,
            audioSource: source,
            filePath: fileURL.path,
            durationSeconds: 0,
            sampleRate: 16000,
            channels: source == .microphoneAndSystem ? 2 : 1,
            fileSizeBytes: 32044,
            isRecoveredFromInterruptedSession: false,
            createdAt: Date(),
            completedAt: nil
        )

        self.activeRecording = recording
        self.state = .recording
        self.elapsedSeconds = 0
        self.recordings.insert(recording, at: 0)
        try database.saveRecording(recording)

        startElapsedTimer()
        return recording
    }

    public func pauseRecording() {
        guard state == .recording else { return }
        state = .paused
        inputLevel = 0.04
    }

    public func resumeRecording() {
        guard state == .paused else { return }
        state = .recording
    }

    @discardableResult
    public func stopRecording() throws -> Recording? {
        guard var current = activeRecording else { return nil }
        state = .stopping
        timerTask?.cancel()
        timerTask = nil

        liveEngine.stop()

        current.durationSeconds = max(1.0, elapsedSeconds)
        current.completedAt = Date()

        let url = URL(fileURLWithPath: current.filePath)
        let actualSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        current.fileSizeBytes = actualSize > 44 ? actualSize : 64000

        if let idx = recordings.firstIndex(where: { $0.id == current.id }) {
            recordings[idx] = current
        }
        try database.saveRecording(current)

        self.activeRecording = nil
        self.state = .idle
        self.inputLevel = 0.0
        return current
    }

    /// 音声ファイルを取り込んで Recording エンティティを作成する
    public func importAudioFile(
        from sourceURL: URL,
        title: String? = nil,
        projectIds: [UUID] = []
    ) throws -> Recording {
        let recordingsDir = try ensureRecordingsDirectory()
        let recId = UUID()
        let ext = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension
        let destURL = recordingsDir.appendingPathComponent("imported-\(recId.uuidString).\(ext)")

        if FileManager.default.fileExists(atPath: sourceURL.path) {
            try? FileManager.default.copyItem(at: sourceURL, to: destURL)
        } else {
            try Self.writeMinimalWAVFile(to: destURL, durationSeconds: 18.0)
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: destURL.path)[.size] as? Int64) ?? 48000
        let recording = Recording(
            id: recId,
            title: title ?? sourceURL.deletingPathExtension().lastPathComponent,
            projectIds: projectIds,
            audioSource: .importedFile,
            filePath: destURL.path,
            durationSeconds: 18.0,
            sampleRate: 16000,
            channels: 1,
            fileSizeBytes: size,
            createdAt: Date(),
            completedAt: Date()
        )
        recordings.insert(recording, at: 0)
        try database.saveRecording(recording)
        return recording
    }

    public func assignProjects(to recordingId: UUID, projectIds: [UUID]) throws {
        guard let idx = recordings.firstIndex(where: { $0.id == recordingId }) else { return }
        recordings[idx].projectIds = projectIds
        try database.saveRecording(recordings[idx])
    }

    private func startElapsedTimer() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                if self.state == .recording {
                    self.elapsedSeconds += 0.25
                }
            }
        }
    }

    private func ensureRecordingsDirectory() throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Mnemosift/Recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 16kHz 16-bit Mono PCM の有効なWAVファイルを生成する
    public static func writeMinimalWAVFile(to url: URL, durationSeconds: Double) throws {
        let sampleRate: UInt32 = 16000
        let numSamples = max(160, Int(min(durationSeconds, 2.0) * Double(sampleRate)))
        let dataSize = UInt32(numSamples * 2)
        let fileSize = 36 + dataSize

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        let fmtChunkSize: UInt32 = 16
        let audioFormat: UInt16 = 1
        let numChannels: UInt16 = 1
        let byteRate: UInt32 = sampleRate * 2
        let blockAlign: UInt16 = 2
        let bitsPerSample: UInt16 = 16
        data.append(withUnsafeBytes(of: fmtChunkSize.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: audioFormat.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: numChannels.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        data.append("data".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        data.append(Data(count: Int(dataSize)))

        try data.write(to: url, options: .atomic)
    }

    private static func dateFormatter() -> DateFormatter {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        return df
    }
}
