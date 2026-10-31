import Foundation

public enum AIModelCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case stt = "STT"
    case judge = "判断モデル"
    case llm = "LLM"
    case embedding = "Embedding"

    public var id: String { rawValue }

    public var description: String {
        switch self {
        case .stt: "音声認識・文字起こし"
        case .judge: "専門用語補正・候補選択・高速分類 (System One)"
        case .llm: "議事録生成・高度な文章補正・RAG質問回答"
        case .embedding: "意味検索・類似文書検索・RAGインデックス"
        }
    }
}

public enum AIModelRuntime: String, Codable, CaseIterable, Sendable {
    case appleSpeech = "Apple Speech (On-Device)"
    case whisperKit = "WhisperKit / Core ML"
    case qwenASR = "Qwen3-ASR (MLX)"
    case kotobaWhisper = "kotoba-whisper (MLX/Local)"
    case appleNaturalLanguage = "Apple NaturalLanguage"
    case modernBERT = "ModernBERT-Ja (MLX)"
    case gliFormer = "GLiFormer (MLX)"
    case ollama = "Ollama Local Runtime"
    case mlxLLM = "MLX LM Local Runtime"
    case builtInEngine = "Built-in Local Engine"
}

public enum StreamingCapability: String, Codable, CaseIterable, Sendable {
    case nativeStreaming = "ネイティブストリーミング"
    case chunkedPseudoStreaming = "チャンク逐次認識（疑似ストリーミング）"
    case batchOnly = "バッチ処理のみ"
}

public enum ModelDownloadState: String, Codable, CaseIterable, Sendable {
    case notInstalled = "未インストール"
    case downloading = "ダウンロード中"
    case installed = "インストール済み"
    case updateAvailable = "更新あり"
    case failed = "エラー"
}

/// Entity #13: AIModel
public struct AIModel: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: String
    public var name: String
    public var category: AIModelCategory
    public var version: String
    public var downloadState: ModelDownloadState
    public var downloadProgress: Double
    public var runtime: AIModelRuntime
    public var requiredMemoryMB: Int
    public var supportedOS: String
    public var supportsJapanese: Bool
    public var streamingCapability: StreamingCapability
    public var supportsCustomVocabulary: Bool
    public var diskSizeMB: Int
    public var endpointOrPath: String
    public var license: String
    public var notes: String

    public init(
        id: String,
        name: String,
        category: AIModelCategory,
        version: String,
        downloadState: ModelDownloadState,
        downloadProgress: Double = 1.0,
        runtime: AIModelRuntime,
        requiredMemoryMB: Int,
        supportedOS: String = "macOS 14+ (Apple Silicon)",
        supportsJapanese: Bool = true,
        streamingCapability: StreamingCapability = .batchOnly,
        supportsCustomVocabulary: Bool = false,
        diskSizeMB: Int,
        endpointOrPath: String = "",
        license: String = "Apache-2.0",
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.version = version
        self.downloadState = downloadState
        self.downloadProgress = downloadProgress
        self.runtime = runtime
        self.requiredMemoryMB = requiredMemoryMB
        self.supportedOS = supportedOS
        self.supportsJapanese = supportsJapanese
        self.streamingCapability = streamingCapability
        self.supportsCustomVocabulary = supportsCustomVocabulary
        self.diskSizeMB = diskSizeMB
        self.endpointOrPath = endpointOrPath
        self.license = license
        self.notes = notes
    }
}

public enum RealtimeCorrectionMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case off = "off"
    case dictionary = "dictionary"
    case fastAI = "fastAI"
    case highPrecisionAI = "highPrecisionAI"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: "モード1：補正オフ"
        case .dictionary: "モード2：辞書補正"
        case .fastAI: "モード3：高速AI補正（推奨）"
        case .highPrecisionAI: "モード4：高精度AI補正（LLM）"
        }
    }

    public var subtitle: String {
        switch self {
        case .off: "STT結果をそのまま表示（最軽量）"
        case .dictionary: "登録済み用語と明確な表記揺れのみを高速置換（LLM不使用）"
        case .fastAI: "辞書候補を小型判断モデルで文脈評価し、確信度が高い場合のみ補正"
        case .highPrecisionAI: "LLMとプロジェクト資料・文脈を用いて高精度に補正（高負荷）"
        }
    }
}

public enum AISettingsScope: String, Codable, CaseIterable, Sendable {
    case global = "global"
    case project = "project"
    case runtimeOverride = "runtimeOverride"
}

/// Entity #14: AISettings
public struct AISettings: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var scope: AISettingsScope
    public var projectId: UUID?
    public var realtimeSTTModelId: String
    public var reprocessSTTModelId: String
    public var judgeModelId: String
    public var llmModelId: String
    public var embeddingModelId: String
    public var correctionMode: RealtimeCorrectionMode
    public var enableHighPrecisionReprocess: Bool
    public var judgeConfidenceThreshold: Double
    public var maxConcurrentJobs: Int
    public var memoryReserveMB: Int
    public var storageRootPath: String
    public var defaultAudioSource: AudioSourceType
    public var updatedAt: Date

    public init(
        id: String = "global-settings",
        scope: AISettingsScope = .global,
        projectId: UUID? = nil,
        realtimeSTTModelId: String = "stt-qwen3-asr-0.6b",
        reprocessSTTModelId: String = "stt-whisper-large-v3-turbo",
        judgeModelId: String = "judge-modernbert-ja",
        llmModelId: String = "llm-gemma-4",
        embeddingModelId: String = "emb-embedding-gemma-2",
        correctionMode: RealtimeCorrectionMode = .fastAI,
        enableHighPrecisionReprocess: Bool = true,
        judgeConfidenceThreshold: Double = 0.72,
        maxConcurrentJobs: Int = 2,
        memoryReserveMB: Int = 2048,
        storageRootPath: String = "",
        defaultAudioSource: AudioSourceType = .microphone,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.scope = scope
        self.projectId = projectId
        self.realtimeSTTModelId = realtimeSTTModelId
        self.reprocessSTTModelId = reprocessSTTModelId
        self.judgeModelId = judgeModelId
        self.llmModelId = llmModelId
        self.embeddingModelId = embeddingModelId
        self.correctionMode = correctionMode
        self.enableHighPrecisionReprocess = enableHighPrecisionReprocess
        self.judgeConfidenceThreshold = judgeConfidenceThreshold
        self.maxConcurrentJobs = maxConcurrentJobs
        self.memoryReserveMB = memoryReserveMB
        self.storageRootPath = storageRootPath
        self.defaultAudioSource = defaultAudioSource
        self.updatedAt = updatedAt
    }
}
