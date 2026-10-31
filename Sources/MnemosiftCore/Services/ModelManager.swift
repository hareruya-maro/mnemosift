import Foundation
import Observation

/// 実行時・プロジェクト・グローバルの3段階優先順位を解決した結果
public struct ResolvedAIConfiguration: Sendable, Equatable {
    public let realtimeSTTModel: AIModel
    public let reprocessSTTModel: AIModel
    public let judgeModel: AIModel
    public let llmModel: AIModel
    public let embeddingModel: AIModel
    public let correctionMode: RealtimeCorrectionMode
    public let enableHighPrecisionReprocess: Bool
    public let judgeConfidenceThreshold: Double
    public let appliedScopeLabel: String
}

/// AIモデルのカタログ、インストール状態、ロード済みモデル、および設定優先順位を管理するマネージャー
@Observable
@MainActor
public final class ModelManager {
    private let database: LocalDatabase
    public private(set) var models: [AIModel] = []
    public private(set) var loadedModelIds: Set<String> = []
    public var globalSettings: AISettings
    public var needsInitialSetupOnboarding: Bool = false

    public init(database: LocalDatabase) {
        self.database = database
        if let savedSettings = try? database.loadGlobalAISettings() {
            self.globalSettings = savedSettings
        } else {
            let defaultRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Mnemosift/ManagedFiles", isDirectory: true).path
            let initial = AISettings(storageRootPath: defaultRoot)
            self.globalSettings = initial
            try? database.saveAISettings(initial)
        }

        let storedModels = (try? database.loadAIModels()) ?? []
        if storedModels.isEmpty {
            let defaults = Self.defaultModelCatalog()
            self.models = defaults
            for model in defaults {
                try? database.saveAIModel(model)
            }
            self.needsInitialSetupOnboarding = true
        } else {
            self.models = storedModels
        }
    }

    public static func defaultModelCatalog() -> [AIModel] {
        [
            // STT Models
            AIModel(
                id: "stt-qwen3-asr-0.6b",
                name: "Qwen3-ASR 0.6B",
                category: .stt,
                version: "1.0.0",
                downloadState: .installed,
                runtime: .qwenASR,
                requiredMemoryMB: 1200,
                supportsJapanese: true,
                streamingCapability: .chunkedPseudoStreaming,
                supportsCustomVocabulary: true,
                diskSizeMB: 640,
                endpointOrPath: "mlx-community/Qwen3-ASR-0.6B-4bit",
                license: "Apache-2.0",
                notes: "軽量・低遅延な日本語/多言語ASR。8GBメモリ環境でも快適動作。"
            ),
            AIModel(
                id: "stt-qwen3-asr-1.7b",
                name: "Qwen3-ASR 1.7B",
                category: .stt,
                version: "1.0.0",
                downloadState: .notInstalled,
                downloadProgress: 0.0,
                runtime: .qwenASR,
                requiredMemoryMB: 3400,
                supportsJapanese: true,
                streamingCapability: .chunkedPseudoStreaming,
                supportsCustomVocabulary: true,
                diskSizeMB: 1750,
                endpointOrPath: "mlx-community/Qwen3-ASR-1.7B-4bit",
                license: "Apache-2.0",
                notes: "高精度な中型ASRモデル。16GB以上のメモリ環境を推奨。"
            ),
            AIModel(
                id: "stt-whisper-large-v3-turbo",
                name: "Whisper Large v3 Turbo (WhisperKit)",
                category: .stt,
                version: "3.1.0",
                downloadState: .installed,
                runtime: .whisperKit,
                requiredMemoryMB: 2200,
                supportsJapanese: true,
                streamingCapability: .chunkedPseudoStreaming,
                supportsCustomVocabulary: true,
                diskSizeMB: 1560,
                endpointOrPath: "argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo",
                license: "MIT",
                notes: "Apple Neural Engine 最適化済み。録音終了後の高精度再処理にも最適。"
            ),
            AIModel(
                id: "stt-apple-speech-ja",
                name: "Apple SpeechAnalyzer / DictationTranscriber",
                category: .stt,
                version: "macOS Built-in",
                downloadState: .installed,
                runtime: .appleSpeech,
                requiredMemoryMB: 450,
                supportsJapanese: true,
                streamingCapability: .nativeStreaming,
                supportsCustomVocabulary: true,
                diskSizeMB: 0,
                endpointOrPath: "system://ja-JP",
                license: "Apple System",
                notes: "OS標準オンデバイス音声認識。ネイティブストリーミングとカスタム語彙に対応。"
            ),
            AIModel(
                id: "stt-kotoba-whisper",
                name: "kotoba-whisper v2.0",
                category: .stt,
                version: "2.0.1",
                downloadState: .notInstalled,
                downloadProgress: 0.0,
                runtime: .kotobaWhisper,
                requiredMemoryMB: 1800,
                supportsJapanese: true,
                streamingCapability: .chunkedPseudoStreaming,
                supportsCustomVocabulary: false,
                diskSizeMB: 1420,
                endpointOrPath: "kotoba-tech/kotoba-whisper-v2.0",
                license: "MIT",
                notes: "日本語音声に特化して蒸留された高速Whisperモデル。"
            ),

            // Judge (System One) Models
            AIModel(
                id: "judge-modernbert-ja",
                name: "Japanese ModernBERT Classifier (System One)",
                category: .judge,
                version: "1.1.0",
                downloadState: .installed,
                runtime: .modernBERT,
                requiredMemoryMB: 350,
                supportsJapanese: true,
                streamingCapability: .batchOnly,
                supportsCustomVocabulary: true,
                diskSizeMB: 290,
                endpointOrPath: "sbintuitions/modernbert-ja-130m",
                license: "Apache-2.0",
                notes: "STT誤認識候補の文脈評価・ファイル分類をミリ秒単位で判定する小型モデル。"
            ),
            AIModel(
                id: "judge-gliformer-ja",
                name: "GLiFormer Zero-Shot Judge",
                category: .judge,
                version: "1.0.2",
                downloadState: .notInstalled,
                downloadProgress: 0.0,
                runtime: .gliFormer,
                requiredMemoryMB: 420,
                supportsJapanese: true,
                streamingCapability: .batchOnly,
                supportsCustomVocabulary: true,
                diskSizeMB: 380,
                endpointOrPath: "mlx-community/gliformer-multilingual-small",
                license: "Apache-2.0",
                notes: "任意のラベル・専門用語に対するゼロショット関連度判定に特化した軽量モデル。"
            ),
            AIModel(
                id: "judge-apple-nl",
                name: "Apple NaturalLanguage + 音韻距離判定器",
                category: .judge,
                version: "macOS Built-in",
                downloadState: .installed,
                runtime: .appleNaturalLanguage,
                requiredMemoryMB: 120,
                supportsJapanese: true,
                streamingCapability: .batchOnly,
                supportsCustomVocabulary: true,
                diskSizeMB: 0,
                endpointOrPath: "system://NaturalLanguage",
                license: "Apple System",
                notes: "追加メモリ消費ほぼゼロで動作する品詞・読み仮名編集距離ベースの高速判定器。"
            ),

            // LLM Models
            AIModel(
                id: "llm-gemma-4",
                name: "Gemma 4 (Local Instruct)",
                category: .llm,
                version: "4.0.0",
                downloadState: .installed,
                runtime: .ollama,
                requiredMemoryMB: 5600,
                supportsJapanese: true,
                streamingCapability: .nativeStreaming,
                supportsCustomVocabulary: true,
                diskSizeMB: 5200,
                endpointOrPath: "http://127.0.0.1:11434/api/generate#gemma4",
                license: "Gemma Terms",
                notes: "標準LLM。議事録生成、高度な文脈補正、RAG質問回答、辞書候補抽出を高精度に実行。"
            ),
            AIModel(
                id: "llm-qwen-2.5-7b",
                name: "Qwen 2.5 7B Instruct (MLX 4bit)",
                category: .llm,
                version: "2.5.0",
                downloadState: .updateAvailable,
                downloadProgress: 1.0,
                runtime: .mlxLLM,
                requiredMemoryMB: 4800,
                supportsJapanese: true,
                streamingCapability: .nativeStreaming,
                supportsCustomVocabulary: true,
                diskSizeMB: 4300,
                endpointOrPath: "mlx-community/Qwen2.5-7B-Instruct-4bit",
                license: "Apache-2.0",
                notes: "日本語と構造化出力に強いApple Silicon MLX最適化モデル。"
            ),
            AIModel(
                id: "llm-builtin-structured",
                name: "Mnemosift Built-in Structured Engine",
                category: .llm,
                version: "1.0.0",
                downloadState: .installed,
                runtime: .builtInEngine,
                requiredMemoryMB: 180,
                supportsJapanese: true,
                streamingCapability: .nativeStreaming,
                supportsCustomVocabulary: true,
                diskSizeMB: 15,
                endpointOrPath: "builtin://structured-engine",
                license: "Proprietary Local",
                notes: "外部ランタイムなし・省メモリ環境でも確実に議事録抽出・RAG回答を行う内蔵エンジン。"
            ),

            // Embedding Models
            AIModel(
                id: "emb-embedding-gemma-2",
                name: "EmbeddingGemma 2",
                category: .embedding,
                version: "2.0.0",
                downloadState: .installed,
                runtime: .ollama,
                requiredMemoryMB: 650,
                supportsJapanese: true,
                streamingCapability: .batchOnly,
                supportsCustomVocabulary: false,
                diskSizeMB: 580,
                endpointOrPath: "embeddinggemma2:latest",
                license: "Gemma Terms",
                notes: "標準Embeddingモデル（256次元正規化ベクトル）。日本語意味検索・RAGに最適化。"
            ),
            AIModel(
                id: "emb-apple-nl-hybrid",
                name: "Apple NLEmbedding Hybrid 256d",
                category: .embedding,
                version: "1.0.0",
                downloadState: .installed,
                runtime: .appleNaturalLanguage,
                requiredMemoryMB: 100,
                supportsJapanese: true,
                streamingCapability: .batchOnly,
                supportsCustomVocabulary: false,
                diskSizeMB: 0,
                endpointOrPath: "system://NLEmbedding-ja",
                license: "Apple System",
                notes: "OS内蔵の単語分散表現と文字N-gramを組み合わせた省メモリEmbeddingモデル。"
            )
        ]
    }

    public func models(for category: AIModelCategory) -> [AIModel] {
        models.filter { $0.category == category }
    }

    public func installedModels(for category: AIModelCategory) -> [AIModel] {
        models.filter {
            $0.category == category && ($0.downloadState == .installed || $0.downloadState == .updateAvailable)
        }
    }

    public func model(withId id: String) -> AIModel? {
        models.first { $0.id == id }
    }

    public var totalDiskUsageMB: Int {
        models
            .filter { $0.downloadState == .installed || $0.downloadState == .updateAvailable }
            .reduce(0) { $0 + $1.diskSizeMB }
    }

    public var activeMemoryFootprintMB: Int {
        models
            .filter { loadedModelIds.contains($0.id) }
            .reduce(0) { $0 + $1.requiredMemoryMB }
    }

    public func loadModelIntoMemory(_ modelId: String) {
        loadedModelIds.insert(modelId)
    }

    public func unloadModelFromMemory(_ modelId: String) {
        loadedModelIds.remove(modelId)
    }

    /// モデルのインストールまたは更新を実行する（ローカルキャッシュ確認および進捗更新）
    public func installOrUpdateModel(id: String) async {
        guard let idx = models.firstIndex(where: { $0.id == id }) else { return }
        models[idx].downloadState = .downloading
        models[idx].downloadProgress = 0.1
        try? database.saveAIModel(models[idx])

        for step in 1...5 {
            try? await Task.sleep(for: .milliseconds(60))
            guard let currentIdx = models.firstIndex(where: { $0.id == id }) else { return }
            models[currentIdx].downloadProgress = Double(step) * 0.2
        }

        guard let finalIdx = models.firstIndex(where: { $0.id == id }) else { return }
        models[finalIdx].downloadState = .installed
        models[finalIdx].downloadProgress = 1.0
        if models[finalIdx].version.hasSuffix(".0") {
            models[finalIdx].version = models[finalIdx].version
        }
        try? database.saveAIModel(models[finalIdx])
    }

    public func deleteModelFromDisk(id: String) throws {
        guard let idx = models.firstIndex(where: { $0.id == id }) else { return }
        // OS内蔵モデルはアンインストール不可
        guard models[idx].diskSizeMB > 0 else { return }
        loadedModelIds.remove(id)
        models[idx].downloadState = .notInstalled
        models[idx].downloadProgress = 0.0
        try database.saveAIModel(models[idx])
    }

    public func updateGlobalSettings(_ updated: AISettings) throws {
        var copy = updated
        copy.updatedAt = Date()
        self.globalSettings = copy
        try database.saveAISettings(copy)
    }

    /// 仕様書 §10.3: 設定の優先順位解決
    /// 1. 実行時の個別指定 (`runtimeOverride`)
    /// 2. プロジェクト固有設定 (`project?.customAISettings`)
    /// 3. アプリ全体の設定 (`globalSettings`)
    public func resolveConfiguration(
        project: Project? = nil,
        runtimeOverride: AISettings? = nil
    ) -> ResolvedAIConfiguration {
        let activeSettings: AISettings
        let scopeLabel: String

        if let runtimeOverride {
            activeSettings = runtimeOverride
            scopeLabel = "1. 実行時の個別指定"
        } else if let projectSettings = project?.customAISettings {
            activeSettings = projectSettings
            scopeLabel = "2. プロジェクト固有設定 (\(project?.name ?? ""))"
        } else {
            activeSettings = globalSettings
            scopeLabel = "3. アプリ全体設定"
        }

        let fallbackSTT = models(for: .stt).first!
        let fallbackJudge = models(for: .judge).first!
        let fallbackLLM = models(for: .llm).first!
        let fallbackEmb = models(for: .embedding).first!

        return ResolvedAIConfiguration(
            realtimeSTTModel: model(withId: activeSettings.realtimeSTTModelId) ?? fallbackSTT,
            reprocessSTTModel: model(withId: activeSettings.reprocessSTTModelId) ?? fallbackSTT,
            judgeModel: model(withId: activeSettings.judgeModelId) ?? fallbackJudge,
            llmModel: model(withId: activeSettings.llmModelId) ?? fallbackLLM,
            embeddingModel: model(withId: activeSettings.embeddingModelId) ?? fallbackEmb,
            correctionMode: activeSettings.correctionMode,
            enableHighPrecisionReprocess: activeSettings.enableHighPrecisionReprocess,
            judgeConfidenceThreshold: activeSettings.judgeConfidenceThreshold,
            appliedScopeLabel: scopeLabel
        )
    }
}
