import Foundation
import Observation

/// 仕様書 §8: AI検索・マルチファクターランキング・RAGチャットサービス
/// - 3つの検索範囲モード（全体検索、プロジェクト優先検索、プロジェクト限定検索）を厳密に区別
/// - 意味的類似度・キーワード一致・ファイル名一致・プロジェクト一致・更新日時減衰・重要度を考慮し、
///   プロジェクト一致だけで古い資料が優先されることを防ぐ
/// - AIチャット回答に参照元を紐づけ、該当ファイル・議事録への移動を可能にする
@Observable
@MainActor
public final class SearchService {
    private let database: LocalDatabase
    private let modelManager: ModelManager
    private let jobManager: JobManager
    private let embeddingService: EmbeddingService
    private let projectService: ProjectService

    public private(set) var lastSearchResults: [SearchResultItem] = []
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
    }

    /// ハイブリッド検索（ファイル名 + FTS5全文 + キーワード + Embedding意味検索 + マルチファクターランキング）
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
            return []
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
            if let embRecord = embeddingService.embeddingsByChunkId[chunk.id] {
                semanticScore = LocalEmbeddingAdapter.cosineSimilarity(queryVector, embRecord.vector)
            } else {
                let fallbackVec = embAdapter.generateEmbedding(for: "\(chunk.title) \(chunk.content)")
                semanticScore = LocalEmbeddingAdapter.cosineSimilarity(queryVector, fallbackVec)
            }

            // 4. キーワード一致 & FTS5 スコア
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
            let keywordScore = max(termRatio, ftsScore)
            let filenameScore = queryTerms.isEmpty ? 0.0 : Double(titleHits) / Double(queryTerms.count)

            // 最低限の関連性チェック（意味的類似度またはキーワード・ファイル名一致が必要）
            guard semanticScore >= 0.25 || keywordScore > 0.0 || filenameScore > 0.0 else {
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

            results.append(SearchResultItem(chunk: chunk, breakdown: breakdown))
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
}
