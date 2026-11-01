import Foundation
import Observation

/// 仕様書 §8 & ローカルAIドキュメント検索機能 実装仕様書 v1.0 (§7〜§10, §12, §13, §16):
/// AIハイブリッド検索（FTS5 BM25 + ベクター検索 + RRF統合）・マルチファクターランキング・RAGチャットサービス
/// - 3つの検索範囲モード（全体検索、プロジェクト優先検索、プロジェクト限定検索）を厳密に区別
/// - 2階層インデックス（文書要約＋チャンク）と Reciprocal Rank Fusion (`k = 60`) によるドキュメント単位ハイブリッド検索を提供
/// - 意味的類似度・キーワード一致・ファイル名一致・プロジェクト一致・更新日時減衰・重要度・意味極性（肯定/否定・決定/検討・明/暗）を考慮
/// - 検索結果およびAIチャット回答に参照元・文字オフセット・発言時刻を紐づけ、該当ファイル・議事録への移動を可能にする
@Observable
@MainActor
public final class SearchService {
    private let database: LocalDatabase
    private let modelManager: ModelManager
    private let jobManager: JobManager
    private let embeddingService: EmbeddingService
    private let projectService: ProjectService

    public let hybridSearchService: HybridSearchService

    public var selectedHybridMode: HybridSearchExecutionMode = .hybrid
    public private(set) var lastSearchResults: [SearchResultItem] = []
    public private(set) var lastDocumentSearchResults: [DocumentSearchResult] = []
    public private(set) var lastStorageAndSpeedMetrics: IndexStorageAndSpeedMetrics = IndexStorageAndSpeedMetrics()
    public private(set) var lastEvaluationReport: SearchQualityEvaluationReport?
    public private(set) var chatMessages: [ChatMessage] = []

    public init(
        database: LocalDatabase,
        modelManager: ModelManager,
        jobManager: JobManager,
        embeddingService: EmbeddingService,
        projectService: ProjectService
    ) {
        self.database = database
        self.modelManager = modelManager
        self.jobManager = jobManager
        self.embeddingService = embeddingService
        self.projectService = projectService
        self.hybridSearchService = HybridSearchService(
            repository: embeddingService.documentRepository,
            indexManager: embeddingService.indexManager
        )
        self.refreshStorageAndSpeedMetrics()
    }

    /// 仕様書 v1.0 (§7, §8, §9, §10): 2階層インデックス + FTS5 BM25 + ベクター検索 + RRF (`k=60`) によるドキュメント単位ハイブリッド検索
    @discardableResult
    public func searchDocuments(
        query: String,
        mode: HybridSearchExecutionMode? = nil,
        filter: DocumentSearchFilter = DocumentSearchFilter(),
        limit: Int = 20
    ) -> [DocumentSearchResult] {
        let embModel = modelManager.model(withId: modelManager.globalSettings.embeddingModelId)
            ?? modelManager.models(for: .embedding).first!
        let embAdapter = LocalEmbeddingAdapter(model: embModel)
        let activeMode = mode ?? selectedHybridMode

        let docResults = hybridSearchService.searchDocuments(
            query: query,
            mode: activeMode,
            filter: filter,
            embeddingAdapter: embAdapter,
            limit: limit
        )
        self.lastDocumentSearchResults = docResults
        self.refreshStorageAndSpeedMetrics()
        return docResults
    }

    /// §12.3 & §13.2 容量・速度メトリクスを最新状態に更新して取得する
    @discardableResult
    public func refreshStorageAndSpeedMetrics() -> IndexStorageAndSpeedMetrics {
        let embModel = modelManager.model(withId: modelManager.globalSettings.embeddingModelId)
            ?? modelManager.models(for: .embedding).first!
        let embAdapter = LocalEmbeddingAdapter(model: embModel)
        let metrics = embeddingService.documentRepository.computeStorageMetrics(
            activeEmbeddingModelId: embModel.id,
            activeEmbeddingDimension: embAdapter.dimensions,
            lastIndexingDurationMs: embeddingService.indexManager.lastIndexingDurationMs,
            lastSearchTiming: hybridSearchService.lastSearchTiming
        )
        self.lastStorageAndSpeedMetrics = metrics
        return metrics
    }

    /// §11.4 インデックス全体の再生成を実行する
    @discardableResult
    public func regenerateAllSearchIndexes() throws -> Int {
        let embModel = modelManager.model(withId: modelManager.globalSettings.embeddingModelId)
            ?? modelManager.models(for: .embedding).first!
        let embAdapter = LocalEmbeddingAdapter(model: embModel)
        let count = try embeddingService.indexManager.regenerateAllIndexes(embeddingAdapter: embAdapter)
        refreshStorageAndSpeedMetrics()
        return count
    }

    /// §16.5 50件以上の検索クエリと正解文書による検索品質評価スイート（FTS5のみ / ベクター検索のみ / ハイブリッド検索の比較）を実行する
    @discardableResult
    public func runQualityEvaluationSuite() throws -> SearchQualityEvaluationReport {
        let embModel = modelManager.model(withId: modelManager.globalSettings.embeddingModelId)
            ?? modelManager.models(for: .embedding).first!
        let report = try HybridSearchService.runSearchQualityEvaluationSuite(embeddingModel: embModel)
        self.lastEvaluationReport = report
        return report
    }

    /// ハイブリッド検索（ファイル名 + FTS5全文 + キーワード + Embedding意味検索 + RRF連携マルチファクターランキング）
    public func search(
        query: String,
        scopeMode: SearchScopeMode,
        targetProjectId: UUID? = nil,
        sourceTypeFilter: KnowledgeSourceType? = nil,
        limit: Int = 20
    ) -> [SearchResultItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.lastSearchResults = []
            self.lastDocumentSearchResults = []
            return []
        }

        // 1. 2階層 RRF ハイブリッド検索も同時に実行してドキュメント単位結果・位置オフセット・速度メトリクスを更新
        let docTypeFilter: IndexedDocumentType? = switch sourceTypeFilter {
        case .document: .document
        case .meetingMinutes, .transcriptSegment: .meeting
        case nil: nil
        }
        let hybridDocResults = searchDocuments(
            query: trimmed,
            mode: selectedHybridMode,
            filter: DocumentSearchFilter(
                documentType: docTypeFilter,
                scopeMode: scopeMode,
                targetProjectId: targetProjectId
            ),
            limit: limit
        )
        var hybridRRFByDocId: [String: DocumentSearchResult] = [:]
        for item in hybridDocResults {
            hybridRRFByDocId[item.documentId] = item
        }

        let embModel = modelManager.model(withId: modelManager.globalSettings.embeddingModelId)
            ?? modelManager.models(for: .embedding).first!
        let embAdapter = LocalEmbeddingAdapter(model: embModel)
        let queryVector = embAdapter.generateEmbedding(for: trimmed)

        // SQLite FTS5 による全文検索スコア
        let ftsScores = database.searchFTS(query: trimmed, limit: 100)
        let queryTerms = trimmed
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        let now = Date()
        var results: [SearchResultItem] = []

        for chunk in embeddingService.chunks {
            // 1. ソース種別フィルタ
            if let sourceTypeFilter, chunk.sourceType != sourceTypeFilter {
                continue
            }

            // 2. 検索範囲モードの適用（プロジェクト限定 vs プロジェクト優先 vs 全体）
            let belongsToTargetProject = targetProjectId.map { chunk.projectIds.contains($0) } ?? false
            if scopeMode == .projectExclusive {
                guard belongsToTargetProject else { continue }
            }

            // 3. Embedding 意味的類似度
            let semanticScore: Double
            if let embRecord = embeddingService.embeddingsByChunkId[chunk.id],
               embRecord.vector.count == queryVector.count {
                semanticScore = LocalEmbeddingAdapter.cosineSimilarity(queryVector, embRecord.vector)
            } else {
                let fallbackVec = embAdapter.generateEmbedding(for: "\(chunk.title) \(chunk.content)")
                semanticScore = LocalEmbeddingAdapter.cosineSimilarity(queryVector, fallbackVec)
            }

            // 4. キーワード一致 & FTS5 スコア & 2階層RRFハイブリッド検索スコア反映
            let lowerContent = chunk.content.lowercased()
            let lowerTitle = chunk.title.lowercased()
            var directTermHits = 0
            var titleHits = 0
            for term in queryTerms {
                if lowerContent.contains(term) { directTermHits += 1 }
                if lowerTitle.contains(term) { titleHits += 1 }
            }
            let termRatio = queryTerms.isEmpty ? 0.0 : Double(directTermHits) / Double(queryTerms.count)
            let ftsScore = ftsScores[chunk.id] ?? 0.0
            let rrfBonus = (hybridRRFByDocId[chunk.sourceId.uuidString]?.rrfScore ?? 0.0) * 15.0
            let keywordScore = min(1.0, max(termRatio, ftsScore, rrfBonus))
            let filenameScore = queryTerms.isEmpty ? 0.0 : Double(titleHits) / Double(queryTerms.count)

            // 最低限の関連性チェック（意味的類似度またはキーワード・ファイル名一致が必要）
            guard semanticScore >= 0.20 || keywordScore > 0.0 || filenameScore > 0.0 else {
                continue
            }

            // 5. 更新日時スコア（仕様書 §8.3: 古い資料がプロジェクト一致だけで優先されないように時間減衰を計算）
            let ageDays = max(0.0, now.timeIntervalSince(chunk.sourceUpdatedAt) / 86400.0)
            // 半減期約30日の滑らかな減衰 [0.15, 1.0]
            let recencyScore = max(0.15, 1.0 / (1.0 + (ageDays / 30.0)))

            // 6. プロジェクト一致スコア（鮮度 recencyScore を掛け合わせることで、極端に古いプロジェクト資料の不当な優先を防止）
            let projectBoost: Double
            if scopeMode == .projectPriority && belongsToTargetProject {
                projectBoost = 0.14 * (0.4 + 0.6 * recencyScore)
            } else if belongsToTargetProject {
                projectBoost = 0.05 * recencyScore
            } else {
                projectBoost = 0.0
            }

            // 7. 決定事項・重要チャンクボーナス
            let importanceBonus = chunk.isDecisionOrImportant ? 0.08 : 0.0

            // 総合ランキングスコア算出
            let totalScore =
                (semanticScore * 0.38) +
                (keywordScore * 0.28) +
                (filenameScore * 0.10) +
                (recencyScore * 0.16) +
                projectBoost +
                importanceBonus

            let breakdown = SearchScoreBreakdown(
                semanticSimilarity: semanticScore,
                keywordMatchScore: keywordScore,
                filenameMatchScore: filenameScore,
                projectAlignmentScore: projectBoost,
                recencyScore: recencyScore,
                importanceScore: importanceBonus,
                totalScore: totalScore
            )

            // 2階層ハイブリッド検索で算出された文字オフセット・時刻ヒントがあれば locationHint を補強
            var enrichedChunk = chunk
            if let docHit = hybridRRFByDocId[chunk.sourceId.uuidString],
               !docHit.locationHintText.isEmpty,
               !enrichedChunk.locationHint.contains("文字位置") {
                enrichedChunk.locationHint = "\(chunk.locationHint) [\(docHit.locationHintText)]"
            }

            results.append(SearchResultItem(chunk: enrichedChunk, breakdown: breakdown))
        }

        // Google Drive ドキュメント（`sourceType == .googleDrive`）等、2階層インデックスのみに登録されている検索結果も横断検索・RAG対象へ統合 (§1.1, §7.2, §13.4)
        let coveredSourceUUIDs = Set(results.map { $0.chunk.sourceId.uuidString })
        for docHit in hybridDocResults where !coveredSourceUUIDs.contains(docHit.documentId) {
            if let sourceTypeFilter, sourceTypeFilter != .document {
                continue
            }
            let deterministicUUID = UUID(uuidString: docHit.documentId) ?? Self.deterministicUUID(from: docHit.documentId)
            let snippetText = docHit.snippet.isEmpty ? docHit.summary : docHit.snippet
            let synthChunk = KnowledgeChunk(
                id: deterministicUUID,
                sourceType: .document,
                sourceId: deterministicUUID,
                projectIds: docHit.projectIds,
                title: docHit.title,
                content: snippetText,
                chunkIndex: docHit.bestChunkIndex ?? 0,
                locationHint: docHit.sourceType == .googleDrive
                    ? "Google ドキュメント [\(docHit.locationHintText)]"
                    : docHit.locationHintText,
                isDecisionOrImportant: false,
                sourceUpdatedAt: docHit.updatedAt
            )
            let breakdown = SearchScoreBreakdown(
                semanticSimilarity: docHit.cosineSimilarity ?? 0.5,
                keywordMatchScore: min(1.0, docHit.rrfScore * 15.0),
                filenameMatchScore: docHit.title.localizedCaseInsensitiveContains(trimmed) ? 1.0 : 0.0,
                projectAlignmentScore: 0.0,
                recencyScore: 0.85,
                importanceScore: 0.0,
                totalScore: max(0.35, docHit.combinedScore)
            )
            results.append(SearchResultItem(chunk: synthChunk, breakdown: breakdown))
        }

        let sorted = results.sorted { $0.breakdown.totalScore > $1.breakdown.totalScore }
        let limited = Array(sorted.prefix(limit))
        self.lastSearchResults = limited
        return limited
    }

    /// 仕様書 §8.4: AIチャット（RAGによる自然言語回答生成＋参照元リンク付与）
    @discardableResult
    public func askQuestion(
        question: String,
        scopeMode: SearchScopeMode,
        targetProjectId: UUID? = nil
    ) async throws -> ChatMessage {
        let userMessage = ChatMessage(
            isUser: true,
            content: question,
            searchScope: scopeMode,
            projectId: targetProjectId
        )
        chatMessages.append(userMessage)

        let ranked = search(
            query: question,
            scopeMode: scopeMode,
            targetProjectId: targetProjectId,
            limit: 6
        )

        let project = projectService.project(for: targetProjectId)
        let config = modelManager.resolveConfiguration(project: project)
        let adapter = LocalLLMAdapter(model: config.llmModel)

        let ragOutput = try await adapter.generateRAGAnswer(
            question: question,
            rankedResults: ranked,
            project: project
        )

        let assistantMessage = ChatMessage(
            isUser: false,
            content: ragOutput.answerText,
            citations: ragOutput.citations,
            hasSufficientEvidence: ragOutput.hasSufficientEvidence,
            searchScope: scopeMode,
            projectId: targetProjectId,
            modelId: config.llmModel.id
        )
        chatMessages.append(assistantMessage)
        return assistantMessage
    }

    public func clearChatHistory() {
        chatMessages.removeAll()
    }

    private nonisolated static func deterministicUUID(from text: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        let utf8 = Array(text.utf8)
        for (i, b) in utf8.enumerated() {
            bytes[i % 16] ^= b &+ UInt8(truncatingIfNeeded: i &* 31)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
