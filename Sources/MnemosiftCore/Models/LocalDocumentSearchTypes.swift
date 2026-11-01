import Foundation

// MARK: - §4 データモデル定義（ローカルAIドキュメント検索機能 実装仕様書 v1.0）

/// §4.1 `documents.type` — ドキュメント種別
public enum IndexedDocumentType: String, Codable, CaseIterable, Sendable, Identifiable {
    case meeting = "meeting"
    case document = "document"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .meeting: "会議・議事録"
        case .document: "ドキュメント"
        }
    }
}

/// §4.1 `documents.source_type` — ドキュメント参照元種別
public enum IndexedDocumentSourceType: String, Codable, CaseIterable, Sendable, Identifiable {
    case local = "local"
    case external = "external"
    case googleDrive = "google_drive"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .local: "アプリ内登録・議事録"
        case .external: "ローカルファイル"
        case .googleDrive: "Google ドキュメント"
        }
    }
}

/// §4.1 `documents.index_status` — インデックス作成状態
public enum DocumentIndexStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case pending = "pending"
    case processing = "processing"
    case ready = "ready"
    case error = "error"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pending: "インデックス待機中"
        case .processing: "インデックス生成中"
        case .ready: "検索可能 (Ready)"
        case .error: "エラー (再試行対象)"
        }
    }
}

/// §4.4 `search_units.unit_type` — 検索単位種別（2階層インデックス）
public enum SearchUnitType: String, Codable, CaseIterable, Sendable {
    case document = "document"
    case chunk = "chunk"
}

/// §4.1 `documents` テーブル対応モデル
public struct IndexedDocumentRecord: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var title: String
    public var type: IndexedDocumentType
    public var sourceType: IndexedDocumentSourceType
    public var sourceURI: String
    public var summary: String
    public var createdAt: Date
    public var updatedAt: Date
    public var occurredAt: Date?
    public var contentHash: String
    public var contentVersion: Int
    public var indexingVersion: Int
    public var indexStatus: DocumentIndexStatus
    public var indexedAt: Date?
    public var projectIds: [UUID]
    public var participants: [String]
    public var errorMessage: String?

    public init(
        id: String = UUID().uuidString,
        title: String,
        type: IndexedDocumentType,
        sourceType: IndexedDocumentSourceType = .local,
        sourceURI: String = "",
        summary: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        occurredAt: Date? = nil,
        contentHash: String = "",
        contentVersion: Int = 1,
        indexingVersion: Int = 1,
        indexStatus: DocumentIndexStatus = .pending,
        indexedAt: Date? = nil,
        projectIds: [UUID] = [],
        participants: [String] = [],
        errorMessage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.type = type
        self.sourceType = sourceType
        self.sourceURI = sourceURI
        self.summary = summary
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.occurredAt = occurredAt
        self.contentHash = contentHash
        self.contentVersion = contentVersion
        self.indexingVersion = indexingVersion
        self.indexStatus = indexStatus
        self.indexedAt = indexedAt
        self.projectIds = projectIds
        self.participants = participants
        self.errorMessage = errorMessage
    }
}

/// §4.2 `document_contents` テーブル対応モデル（元テキスト保持・検索用正規化テキストと分離）
public struct DocumentContentRecord: Codable, Sendable, Equatable, Hashable {
    public var documentId: String
    public var rawText: String
    public var isExternalCacheOnly: Bool
    public var isSourceAccessible: Bool
    public var updatedAt: Date

    public init(
        documentId: String,
        rawText: String,
        isExternalCacheOnly: Bool = false,
        isSourceAccessible: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.documentId = documentId
        self.rawText = rawText
        self.isExternalCacheOnly = isExternalCacheOnly
        self.isSourceAccessible = isSourceAccessible
        self.updatedAt = updatedAt
    }
}

/// §4.3 `document_chunks` テーブル対応モデル
/// - `startOffset` / `endOffset` は Swift `String` の文字位置（Character Index / Extended Grapheme Cluster 単位、かつ UTF-16/UnicodeScalar 変換可能）として統一し、マルチバイト文字でも元文書に正確にジャンプできる
public struct DocumentChunkRecord: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var documentId: String
    public var chunkIndex: Int
    public var text: String
    public var startOffset: Int
    public var endOffset: Int
    public var startTimeMs: Int64?
    public var endTimeMs: Int64?
    public var contentHash: String

    public init(
        id: String = UUID().uuidString,
        documentId: String,
        chunkIndex: Int,
        text: String,
        startOffset: Int,
        endOffset: Int,
        startTimeMs: Int64? = nil,
        endTimeMs: Int64? = nil,
        contentHash: String
    ) {
        self.id = id
        self.documentId = documentId
        self.chunkIndex = chunkIndex
        self.text = text
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.startTimeMs = startTimeMs
        self.endTimeMs = endTimeMs
        self.contentHash = contentHash
    }
}

/// §4.4 `search_units` テーブル対応モデル
/// - 文書要約 (`unit_type = .document`) と個別チャンク (`unit_type = .chunk`) を統一的に扱う
/// - チャンク側にはタイトル (`titleTerms`) を重複保存しない（空文字列にする）
public struct SearchUnitRecord: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: Int64
    public var documentId: String
    public var chunkId: String?
    public var unitType: SearchUnitType
    public var titleTerms: String
    public var keywords: String
    public var bodyTerms: String

    public init(
        id: Int64 = 0,
        documentId: String,
        chunkId: String? = nil,
        unitType: SearchUnitType,
        titleTerms: String,
        keywords: String,
        bodyTerms: String
    ) {
        self.id = id
        self.documentId = documentId
        self.chunkId = chunkId
        self.unitType = unitType
        self.titleTerms = titleTerms
        self.keywords = keywords
        self.bodyTerms = bodyTerms
    }
}

/// §4.6 `embeddings` テーブル対応モデル
public struct StoredVectorRecord: Codable, Sendable, Equatable, Hashable {
    public var searchUnitId: Int64
    public var embeddingModelId: String
    public var embeddingDimension: Int
    public var embeddingVersion: Int
    public var generatedAt: Date
    public var vector: [Float]

    public init(
        searchUnitId: Int64,
        embeddingModelId: String,
        embeddingDimension: Int,
        embeddingVersion: Int = 1,
        generatedAt: Date = Date(),
        vector: [Float]
    ) {
        self.searchUnitId = searchUnitId
        self.embeddingModelId = embeddingModelId
        self.embeddingDimension = embeddingDimension
        self.embeddingVersion = embeddingVersion
        self.generatedAt = generatedAt
        self.vector = vector
    }
}

// MARK: - §7, §8, §9, §10 ハイブリッド検索設定・フィルタ・結果モデル

/// 検索実行モード（§16.5 比較評価および §14 フォールバック用）
public enum HybridSearchExecutionMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case hybrid = "hybrid"
    case ftsOnly = "ftsOnly"
    case vectorOnly = "vectorOnly"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .hybrid: "ハイブリッド検索 (FTS5 + ベクター + RRF)"
        case .ftsOnly: "FTS5 全文検索のみ (BM25)"
        case .vectorOnly: "ベクター意味検索のみ (Cosine)"
        }
    }
}

/// §5.3, §7.2, §9.2, §9.3 ハイブリッド検索・インデックス設定パラメータ
public struct HybridSearchConfiguration: Codable, Sendable, Equatable, Hashable {
    public var titleBM25Weight: Double
    public var keywordBM25Weight: Double
    public var bodyBM25Weight: Double
    public var ftsCandidateLimit: Int
    public var vectorCandidateLimit: Int
    public var finalDocumentLimit: Int
    public var rrfK: Double
    public var ftsRRFWeight: Double
    public var vectorRRFWeight: Double
    public var targetMinChunkTokens: Int
    public var targetMaxChunkTokens: Int
    public var chunkOverlapRatio: Double
    public var indexingVersion: Int
    public var omitRedundantChunkVectorForSingleShortChunk: Bool

    public init(
        titleBM25Weight: Double = 8.0,
        keywordBM25Weight: Double = 4.0,
        bodyBM25Weight: Double = 1.0,
        ftsCandidateLimit: Int = 100,
        vectorCandidateLimit: Int = 100,
        finalDocumentLimit: Int = 20,
        rrfK: Double = 60.0,
        ftsRRFWeight: Double = 1.0,
        vectorRRFWeight: Double = 1.0,
        targetMinChunkTokens: Int = 250,
        targetMaxChunkTokens: Int = 400,
        chunkOverlapRatio: Double = 0.08,
        indexingVersion: Int = 1,
        omitRedundantChunkVectorForSingleShortChunk: Bool = true
    ) {
        self.titleBM25Weight = titleBM25Weight
        self.keywordBM25Weight = keywordBM25Weight
        self.bodyBM25Weight = bodyBM25Weight
        self.ftsCandidateLimit = ftsCandidateLimit
        self.vectorCandidateLimit = vectorCandidateLimit
        self.finalDocumentLimit = finalDocumentLimit
        self.rrfK = rrfK
        self.ftsRRFWeight = ftsRRFWeight
        self.vectorRRFWeight = vectorRRFWeight
        self.targetMinChunkTokens = targetMinChunkTokens
        self.targetMaxChunkTokens = targetMaxChunkTokens
        self.chunkOverlapRatio = chunkOverlapRatio
        self.indexingVersion = indexingVersion
        self.omitRedundantChunkVectorForSingleShortChunk = omitRedundantChunkVectorForSingleShortChunk
    }
}

/// §9.4 構造化メタデータ検索フィルタ
public struct DocumentSearchFilter: Codable, Sendable, Equatable, Hashable {
    public var documentType: IndexedDocumentType?
    public var occurredAfter: Date?
    public var occurredBefore: Date?
    public var participantQuery: String?
    public var scopeMode: SearchScopeMode
    public var targetProjectId: UUID?

    public init(
        documentType: IndexedDocumentType? = nil,
        occurredAfter: Date? = nil,
        occurredBefore: Date? = nil,
        participantQuery: String? = nil,
        scopeMode: SearchScopeMode = .global,
        targetProjectId: UUID? = nil
    ) {
        self.documentType = documentType
        self.occurredAfter = occurredAfter
        self.occurredBefore = occurredBefore
        self.participantQuery = participantQuery
        self.scopeMode = scopeMode
        self.targetProjectId = targetProjectId
    }
}

/// §13.2 検索処理時間の内訳メトリクス
public struct SearchTimingMetrics: Codable, Sendable, Equatable, Hashable {
    public var queryAnalysisMs: Double
    public var queryEmbeddingMs: Double
    public var ftsSearchMs: Double
    public var vectorSearchMs: Double
    public var rrfFusionMs: Double
    public var totalSearchMs: Double

    public init(
        queryAnalysisMs: Double = 0,
        queryEmbeddingMs: Double = 0,
        ftsSearchMs: Double = 0,
        vectorSearchMs: Double = 0,
        rrfFusionMs: Double = 0,
        totalSearchMs: Double = 0
    ) {
        self.queryAnalysisMs = queryAnalysisMs
        self.queryEmbeddingMs = queryEmbeddingMs
        self.ftsSearchMs = ftsSearchMs
        self.vectorSearchMs = vectorSearchMs
        self.rrfFusionMs = rrfFusionMs
        self.totalSearchMs = totalSearchMs
    }
}

/// §10 検索結果の表現（ドキュメント単位集約）
public struct DocumentSearchResult: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String { documentId }
    public var documentId: String
    public var title: String
    public var documentType: IndexedDocumentType
    public var sourceType: IndexedDocumentSourceType
    public var sourceURI: String
    public var createdAt: Date
    public var updatedAt: Date
    public var occurredAt: Date?
    public var summary: String
    public var snippet: String
    public var bestChunkId: String?
    public var bestChunkIndex: Int?
    public var startOffset: Int?
    public var endOffset: Int?
    public var startTimeMs: Int64?
    public var endTimeMs: Int64?
    public var combinedScore: Double
    public var rrfScore: Double
    public var ftsRank: Int?
    public var vectorRank: Int?
    public var bm25RawScore: Double?
    public var cosineSimilarity: Double?
    public var matchedKeywords: [String]
    public var projectIds: [UUID]
    public var participants: [String]
    public var isSourceAccessible: Bool

    public init(
        documentId: String,
        title: String,
        documentType: IndexedDocumentType,
        sourceType: IndexedDocumentSourceType,
        sourceURI: String,
        createdAt: Date,
        updatedAt: Date,
        occurredAt: Date?,
        summary: String,
        snippet: String,
        bestChunkId: String?,
        bestChunkIndex: Int?,
        startOffset: Int?,
        endOffset: Int?,
        startTimeMs: Int64?,
        endTimeMs: Int64?,
        combinedScore: Double,
        rrfScore: Double,
        ftsRank: Int?,
        vectorRank: Int?,
        bm25RawScore: Double?,
        cosineSimilarity: Double?,
        matchedKeywords: [String] = [],
        projectIds: [UUID] = [],
        participants: [String] = [],
        isSourceAccessible: Bool = true
    ) {
        self.documentId = documentId
        self.title = title
        self.documentType = documentType
        self.sourceType = sourceType
        self.sourceURI = sourceURI
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.occurredAt = occurredAt
        self.summary = summary
        self.snippet = snippet
        self.bestChunkId = bestChunkId
        self.bestChunkIndex = bestChunkIndex
        self.startOffset = startOffset
        self.endOffset = endOffset
        self.startTimeMs = startTimeMs
        self.endTimeMs = endTimeMs
        self.combinedScore = combinedScore
        self.rrfScore = rrfScore
        self.ftsRank = ftsRank
        self.vectorRank = vectorRank
        self.bm25RawScore = bm25RawScore
        self.cosineSimilarity = cosineSimilarity
        self.matchedKeywords = matchedKeywords
        self.projectIds = projectIds
        self.participants = participants
        self.isSourceAccessible = isSourceAccessible
    }

    /// 表示用の位置ヒント文字列（文字オフセットまたは時刻）
    public var locationHintText: String {
        if let startMs = startTimeMs {
            let sec = Double(startMs) / 1000.0
            let minPart = Int(sec) / 60
            let secPart = Int(sec) % 60
            if let endMs = endTimeMs {
                let endSec = Double(endMs) / 1000.0
                return String(format: "%02d:%02d-%02d:%02d", minPart, secPart, Int(endSec) / 60, Int(endSec) % 60)
            }
            return String(format: "%02d:%02d", minPart, secPart)
        }
        if let s = startOffset, let e = endOffset {
            return "文字位置 \(s)〜\(e)"
        }
        return "文書全体要約"
    }
}

// MARK: - §12.3 & §13.2 容量・速度メトリクスと §16.5 検索品質評価レポート

/// §12.3 データ容量・処理時間メトリクス
public struct IndexStorageAndSpeedMetrics: Codable, Sendable, Equatable, Hashable {
    public var documentCount: Int
    public var readyDocumentCount: Int
    public var chunkCount: Int
    public var searchUnitCount: Int
    public var vectorCount: Int
    public var sqliteFileSizeBytes: Int64
    public var rawTextBytes: Int64
    public var ftsIndexBytes: Int64
    public var vectorBlobBytes: Int64
    public var averageBytesPerDocument: Int64
    public var lastIndexingDurationMs: Double
    public var lastSearchTiming: SearchTimingMetrics
    public var activeEmbeddingModelId: String
    public var activeEmbeddingDimension: Int
    public var vectorBackendName: String

    public init(
        documentCount: Int = 0,
        readyDocumentCount: Int = 0,
        chunkCount: Int = 0,
        searchUnitCount: Int = 0,
        vectorCount: Int = 0,
        sqliteFileSizeBytes: Int64 = 0,
        rawTextBytes: Int64 = 0,
        ftsIndexBytes: Int64 = 0,
        vectorBlobBytes: Int64 = 0,
        averageBytesPerDocument: Int64 = 0,
        lastIndexingDurationMs: Double = 0,
        lastSearchTiming: SearchTimingMetrics = SearchTimingMetrics(),
        activeEmbeddingModelId: String = "",
        activeEmbeddingDimension: Int = 384,
        vectorBackendName: String = "SQLite Vector Adapter (Float32 Cosine)"
    ) {
        self.documentCount = documentCount
        self.readyDocumentCount = readyDocumentCount
        self.chunkCount = chunkCount
        self.searchUnitCount = searchUnitCount
        self.vectorCount = vectorCount
        self.sqliteFileSizeBytes = sqliteFileSizeBytes
        self.rawTextBytes = rawTextBytes
        self.ftsIndexBytes = ftsIndexBytes
        self.vectorBlobBytes = vectorBlobBytes
        self.averageBytesPerDocument = averageBytesPerDocument
        self.lastIndexingDurationMs = lastIndexingDurationMs
        self.lastSearchTiming = lastSearchTiming
        self.activeEmbeddingModelId = activeEmbeddingModelId
        self.activeEmbeddingDimension = activeEmbeddingDimension
        self.vectorBackendName = vectorBackendName
    }
}

/// §16.5 検索品質評価ケース
public struct SearchEvaluationQueryCase: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var category: String
    public var query: String
    public var expectedDocumentId: String
    public var forbiddenTop1DocumentId: String?

    public init(
        id: String,
        category: String,
        query: String,
        expectedDocumentId: String,
        forbiddenTop1DocumentId: String? = nil
    ) {
        self.id = id
        self.category = category
        self.query = query
        self.expectedDocumentId = expectedDocumentId
        self.forbiddenTop1DocumentId = forbiddenTop1DocumentId
    }
}

/// §16.5 検索モード別の評価指標（Recall@1, Recall@5, MRR, 検索時間）
public struct SearchModeEvaluationMetrics: Codable, Sendable, Equatable, Hashable {
    public var mode: HybridSearchExecutionMode
    public var queryCount: Int
    public var recallAt1: Double
    public var recallAt5: Double
    public var mrr: Double
    public var semanticDistinctionAccuracy: Double
    public var averageSearchMs: Double

    public init(
        mode: HybridSearchExecutionMode,
        queryCount: Int,
        recallAt1: Double,
        recallAt5: Double,
        mrr: Double,
        semanticDistinctionAccuracy: Double,
        averageSearchMs: Double
    ) {
        self.mode = mode
        self.queryCount = queryCount
        self.recallAt1 = recallAt1
        self.recallAt5 = recallAt5
        self.mrr = mrr
        self.semanticDistinctionAccuracy = semanticDistinctionAccuracy
        self.averageSearchMs = averageSearchMs
    }
}

/// §16.5 3モード比較評価レポート（FTS5のみ / ベクター検索のみ / ハイブリッド検索）
public struct SearchQualityEvaluationReport: Codable, Sendable, Equatable, Hashable {
    public var evaluatedAt: Date
    public var totalQueries: Int
    public var totalDocuments: Int
    public var ftsOnlyMetrics: SearchModeEvaluationMetrics
    public var vectorOnlyMetrics: SearchModeEvaluationMetrics
    public var hybridMetrics: SearchModeEvaluationMetrics
    public var storageMetrics: IndexStorageAndSpeedMetrics

    public init(
        evaluatedAt: Date = Date(),
        totalQueries: Int,
        totalDocuments: Int,
        ftsOnlyMetrics: SearchModeEvaluationMetrics,
        vectorOnlyMetrics: SearchModeEvaluationMetrics,
        hybridMetrics: SearchModeEvaluationMetrics,
        storageMetrics: IndexStorageAndSpeedMetrics
    ) {
        self.evaluatedAt = evaluatedAt
        self.totalQueries = totalQueries
        self.totalDocuments = totalDocuments
        self.ftsOnlyMetrics = ftsOnlyMetrics
        self.vectorOnlyMetrics = vectorOnlyMetrics
        self.hybridMetrics = hybridMetrics
        self.storageMetrics = storageMetrics
    }
}
