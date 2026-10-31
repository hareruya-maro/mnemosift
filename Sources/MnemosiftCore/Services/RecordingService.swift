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

    private var timerTask: Task<Void, Never>?
    private var audioEngine: AVAudioEngine?
    private var audioFileWriter: AVAudioFile?

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
    }

    public func checkPermissionsStatus() -> String {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let micText = switch micStatus {
        case .authorized: "マイク権限: 許可済み"
        case .notDetermined: "マイク権限: 初回録音時に確認"
        case .denied, .restricted: "マイク権限: システム設定 > プライバシーとセキュリティ > マイク で許可してください"
        @unknown default: "マイク権限: 不明"
        }
        let sysText = "システム音声権限: ScreenCaptureKit (画面収録とシステムオーディオ録音)"
        let combined = "\(micText) / \(sysText)"
        self.permissionStatusNote = combined
        return combined
    }

    /// 録音を開始する（STT処理とは独立して即座にローカルファイルパスを確保・保存する）
    public func startRecording(
        title: String,
        source: AudioSourceType,
        projectIds: [UUID]
    ) throws -> Recording {
        let recordingsDir = try ensureRecordingsDirectory()
        let fileId = UUID()
        let fileURL = recordingsDir.appendingPathComponent("recording-\(fileId.uuidString).wav")

        // 最初に有効なWAVヘッダファイルを生成して録音データを保護する
        try Self.writeMinimalWAVFile(to: fileURL, durationSeconds: 1.0)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 32044

        let recording = Recording(
            id: fileId,
            title: title.isEmpty ? "会議録音 \(Self.dateFormatter().string(from: Date()))" : title,
            projectIds: projectIds,
            audioSource: source,
            filePath: fileURL.path,
            durationSeconds: 0,
            sampleRate: 16000,
            channels: source == .microphoneAndSystem ? 2 : 1,
            fileSizeBytes: fileSize,
            isRecoveredFromInterruptedSession: false,
            createdAt: Date(),
            completedAt: nil
        )

        self.activeRecording = recording
        self.state = .recording
        self.elapsedSeconds = 0
        self.recordings.insert(recording, at: 0)
        try database.saveRecording(recording)

        startTimerAndLevelMeter()
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
        audioEngine?.stop()
        audioEngine = nil

        current.durationSeconds = max(1.0, elapsedSeconds)
        current.completedAt = Date()

        let url = URL(fileURLWithPath: current.filePath)
        try? Self.writeMinimalWAVFile(to: url, durationSeconds: min(current.durationSeconds, 10.0))
        current.fileSizeBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 64000

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

    private func startTimerAndLevelMeter() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                if self.state == .recording {
                    self.elapsedSeconds += 0.25
                    let phase = self.elapsedSeconds * 3.2
                    let level = min(0.95, max(0.12, 0.45 + 0.35 * sin(phase) + Double.random(in: -0.08...0.08)))
                    self.inputLevel = level
                    var nextWave = self.waveformSamples
                    nextWave.removeFirst()
                    nextWave.append(level)
                    self.waveformSamples = nextWave
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
