import Foundation

public enum JobType: String, Codable, CaseIterable, Sendable {
    case realtimeSTT = "リアルタイムSTT"
    case realtimeCorrection = "リアルタイム補正"
    case highPrecisionReprocess = "高精度再処理"
    case meetingMinutesGeneration = "議事録生成"
    case documentParsing = "ファイル解析"
    case documentClassification = "ファイル分類"
    case embeddingGeneration = "Embedding生成"
    case vocabularyExtraction = "専門用語候補抽出"
    case modelDownload = "モデルダウンロード"
    case phase0Benchmark = "Phase 0 技術検証ベンチマーク"
}

public enum JobPriority: Int, Codable, CaseIterable, Sendable, Comparable {
    case lowBackground = 20
    case normal = 50
    case highInteractive = 80
    case criticalRealtime = 100

    public static func < (lhs: JobPriority, rhs: JobPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .criticalRealtime: "最優先（録音・リアルタイムSTT）"
        case .highInteractive: "高（リアルタイム補正・対話）"
        case .normal: "通常（議事録生成・再処理）"
        case .lowBackground: "低（Embedding・ファイル分類）"
        }
    }
}

public enum JobStatus: String, Codable, CaseIterable, Sendable {
    case queued = "待機中"
    case waitingForMemory = "メモリ空き待機中"
    case running = "実行中"
    case completed = "完了"
    case failed = "失敗"
    case cancelled = "キャンセル"
    case interrupted = "異常終了により中断"
}

/// Entity #12: ProcessingJob
public struct ProcessingJob: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var type: JobType
    public var title: String
    public var priority: JobPriority
    public var status: JobStatus
    public var progress: Double
    public var projectId: UUID?
    public var modelId: String
    public var requiredMemoryMB: Int
    public var errorMessage: String?
    public var resultSummary: String?
    public var retryCount: Int
    public var createdAt: Date
    public var startedAt: Date?
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        type: JobType,
        title: String,
        priority: JobPriority,
        status: JobStatus = .queued,
        progress: Double = 0.0,
        projectId: UUID? = nil,
        modelId: String = "",
        requiredMemoryMB: Int = 256,
        errorMessage: String? = nil,
        resultSummary: String? = nil,
        retryCount: Int = 0,
        createdAt: Date = Date(),
        startedAt: Date? = nil,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.type = type
        self.title = title
        self.priority = priority
        self.status = status
        self.progress = progress
        self.projectId = projectId
        self.modelId = modelId
        self.requiredMemoryMB = requiredMemoryMB
        self.errorMessage = errorMessage
        self.resultSummary = resultSummary
        self.retryCount = retryCount
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

public enum WorkspaceMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case meetingPartner = "会議パートナー"
    case knowledgeHub = "資料検索・整理"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .meetingPartner: "waveform.and.person.filled"
        case .knowledgeHub: "books.vertical.fill"
        }
    }
}

public enum NavigationSection: String, Codable, CaseIterable, Sendable, Identifiable {
    case home = "ホーム"
    case recording = "録音・文字起こし"
    case meetings = "議事録"
    case files = "ファイル"
    case searchChat = "AI検索・チャット"
    case projects = "プロジェクト"
    case history = "処理履歴"
    case settings = "設定"

    public var id: String { rawValue }

    public var systemImage: String {
        switch self {
        case .home: "house.fill"
        case .recording: "waveform.badge.mic"
        case .meetings: "doc.text.fill"
        case .files: "folder.fill.badge.gearshape"
        case .searchChat: "sparkle.magnifyingglass"
        case .projects: "square.stack.3d.up.fill"
        case .history: "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .settings: "slider.horizontal.3"
        }
    }
}

public struct BenchmarkMetricRecord: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var scenarioName: String
    public var modelId: String
    public var category: String
    public var inputSample: String
    public var outputSample: String
    public var latencyMs: Double
    public var memoryUsedMB: Int
    public var accuracyScore: Double
    public var passedGuardrails: Bool
    public var notes: String
    public var executedAt: Date

    public init(
        id: UUID = UUID(),
        scenarioName: String,
        modelId: String,
        category: String,
        inputSample: String,
        outputSample: String,
        latencyMs: Double,
        memoryUsedMB: Int,
        accuracyScore: Double,
        passedGuardrails: Bool = true,
        notes: String = "",
        executedAt: Date = Date()
    ) {
        self.id = id
        self.scenarioName = scenarioName
        self.modelId = modelId
        self.category = category
        self.inputSample = inputSample
        self.outputSample = outputSample
        self.latencyMs = latencyMs
        self.memoryUsedMB = memoryUsedMB
        self.accuracyScore = accuracyScore
        self.passedGuardrails = passedGuardrails
        self.notes = notes
        self.executedAt = executedAt
    }
}
