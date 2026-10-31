import Foundation

public enum AudioSourceType: String, Codable, CaseIterable, Sendable, Identifiable {
    case microphone = "microphone"
    case systemAudio = "systemAudio"
    case microphoneAndSystem = "microphoneAndSystem"
    case importedFile = "importedFile"
    case extractedFromVideo = "extractedFromVideo"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .microphone: "マイク録音"
        case .systemAudio: "システム音声録音"
        case .microphoneAndSystem: "マイク＋システム音声同時録音"
        case .importedFile: "音声ファイル取り込み"
        case .extractedFromVideo: "動画から音声抽出"
        }
    }
}

public enum RecordingState: String, Codable, Sendable {
    case idle = "待機中"
    case recording = "録音中"
    case paused = "一時停止中"
    case stopping = "保存処理中"
    case completed = "完了"
    case failed = "エラー"
}

/// Entity #4: Recording
public struct Recording: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var title: String
    public var projectIds: [UUID]
    public var audioSource: AudioSourceType
    public var filePath: String
    public var durationSeconds: Double
    public var sampleRate: Double
    public var channels: Int
    public var fileSizeBytes: Int64
    public var isRecoveredFromInterruptedSession: Bool
    public var createdAt: Date
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        title: String,
        projectIds: [UUID] = [],
        audioSource: AudioSourceType = .microphone,
        filePath: String,
        durationSeconds: Double = 0,
        sampleRate: Double = 16000,
        channels: Int = 1,
        fileSizeBytes: Int64 = 0,
        isRecoveredFromInterruptedSession: Bool = false,
        createdAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.projectIds = projectIds
        self.audioSource = audioSource
        self.filePath = filePath
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
        self.channels = channels
        self.fileSizeBytes = fileSizeBytes
        self.isRecoveredFromInterruptedSession = isRecoveredFromInterruptedSession
        self.createdAt = createdAt
        self.completedAt = completedAt
    }
}

/// Entity #5: Transcript
public struct Transcript: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var recordingId: UUID
    public var title: String
    public var projectIds: [UUID]
    public var sttModelId: String
    public var correctionMode: RealtimeCorrectionMode
    public var language: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        recordingId: UUID,
        title: String,
        projectIds: [UUID] = [],
        sttModelId: String,
        correctionMode: RealtimeCorrectionMode = .fastAI,
        language: String = "ja-JP",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.recordingId = recordingId
        self.title = title
        self.projectIds = projectIds
        self.sttModelId = sttModelId
        self.correctionMode = correctionMode
        self.language = language
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Entity #6: TranscriptSegment
/// STT原文 (`rawText`) と AI補正文 (`correctedText`) を厳密に分離して保持する。
public struct TranscriptSegment: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var transcriptId: UUID
    public var sequenceIndex: Int
    public var startTimeSeconds: Double
    public var endTimeSeconds: Double
    public var speakerLabel: String
    /// STTが認識した原文（AI補正で決して上書きしない）
    public let rawText: String
    /// 現在適用されている補正後テキスト（未補正またはロールバック時は rawText と同一）
    public var correctedText: String
    public var isProvisional: Bool
    public var sttConfidence: Double
    public var activeRevisionId: UUID?
    public var createdAt: Date
    public var updatedAt: Date

    public var hasCorrection: Bool {
        rawText != correctedText
    }

    public init(
        id: UUID = UUID(),
        transcriptId: UUID,
        sequenceIndex: Int,
        startTimeSeconds: Double,
        endTimeSeconds: Double,
        speakerLabel: String = "話者A",
        rawText: String,
        correctedText: String? = nil,
        isProvisional: Bool = false,
        sttConfidence: Double = 0.9,
        activeRevisionId: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.transcriptId = transcriptId
        self.sequenceIndex = sequenceIndex
        self.startTimeSeconds = startTimeSeconds
        self.endTimeSeconds = endTimeSeconds
        self.speakerLabel = speakerLabel
        self.rawText = rawText
        self.correctedText = correctedText ?? rawText
        self.isProvisional = isProvisional
        self.sttConfidence = sttConfidence
        self.activeRevisionId = activeRevisionId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct CorrectionSpan: Codable, Sendable, Equatable, Hashable {
    public var originalFragment: String
    public var correctedFragment: String
    public var reason: String
    public var confidence: Double
    public var vocabularyId: UUID?

    public init(
        originalFragment: String,
        correctedFragment: String,
        reason: String,
        confidence: Double,
        vocabularyId: UUID? = nil
    ) {
        self.originalFragment = originalFragment
        self.correctedFragment = correctedFragment
        self.reason = reason
        self.confidence = confidence
        self.vocabularyId = vocabularyId
    }
}

/// Entity #7: TranscriptRevision
public struct TranscriptRevision: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var segmentId: UUID
    public var transcriptId: UUID
    public let sttRawText: String
    public var correctedText: String
    public var correctionSpans: [CorrectionSpan]
    public var correctionMethod: RealtimeCorrectionMode
    public var modelId: String
    public var guardrailNotes: [String]
    public var isReverted: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        segmentId: UUID,
        transcriptId: UUID,
        sttRawText: String,
        correctedText: String,
        correctionSpans: [CorrectionSpan] = [],
        correctionMethod: RealtimeCorrectionMode,
        modelId: String,
        guardrailNotes: [String] = [],
        isReverted: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.segmentId = segmentId
        self.transcriptId = transcriptId
        self.sttRawText = sttRawText
        self.correctedText = correctedText
        self.correctionSpans = correctionSpans
        self.correctionMethod = correctionMethod
        self.modelId = modelId
        self.guardrailNotes = guardrailNotes
        self.isReverted = isReverted
        self.createdAt = createdAt
    }
}
