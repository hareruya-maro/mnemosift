import Foundation

// MARK: - §7, §8, §9, §10, §13, §14, §16 ハイブリッド検索サービス (`HybridSearchService`)

public final class HybridSearchService: @unchecked Sendable {
    public let repository: DocumentRepository
    public let indexManager: IndexManager
    public let textAnalyzer: any TextAnalyzing
    public var configuration: HybridSearchConfiguration
    public private(set) var lastSearchTiming: SearchTimingMetrics = SearchTimingMetrics()

    public init(
        repository: DocumentRepository,
        indexManager: IndexManager,
        textAnalyzer: any TextAnalyzing = NaturalLanguageTextAnalyzer(),
        configuration: HybridSearchConfiguration = HybridSearchConfiguration()
    ) {
        self.repository = repository
        self.indexManager = indexManager
        self.textAnalyzer = textAnalyzer
        self.configuration = configuration
    }

    /// §9.1〜§9.4, §10 ドキュメント単位ハイブリッド検索（FTS5 BM25 + ベクター検索 + RRF `k=60` 統合）
    public func searchDocuments(
        query: String,
        mode: HybridSearchExecutionMode = .hybrid,
        filter: DocumentSearchFilter = DocumentSearchFilter(),
        embeddingAdapter: any EmbeddingAdapter,
        limit: Int? = nil
    ) -> [DocumentSearchResult] {
        let totalStart = CFAbsoluteTimeGetCurrent()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.lastSearchTiming = SearchTimingMetrics()
            return []
        }

        // 1. クエリ形態素解析・正規化・意味極性シグナル抽出 (§9.1 #1, #2)
        let analysisStart = CFAbsoluteTimeGetCurrent()
        let analyzedTokens = textAnalyzer.analyzeTokens(in: trimmed, titleContext: "")
        let querySignals = textAnalyzer.extractSemanticSignals(in: trimmed)
        let queryTerms = Array(Set(analyzedTokens.filter { $0.tier != .low }.map(\.normalized))).sorted()
        let queryAnalysisMs = (CFAbsoluteTimeGetCurrent() - analysisStart) * 1000.0

        // 2. クエリ Embedding 生成 (§9.1 #3)
        let embStart = CFAbsoluteTimeGetCurrent()
        let queryVector: [Float]
        if mode == .hybrid || mode == .vectorOnly {
            queryVector = embeddingAdapter.generateEmbedding(for: trimmed)
        } else {
            queryVector = []
        }
        let queryEmbeddingMs = (CFAbsoluteTimeGetCurrent() - embStart) * 1000.0

        // 3. FTS5 全文検索実行（上位 100 検索単位）(§7, §9.1 #4, §9.2)
        let ftsStart = CFAbsoluteTimeGetCurrent()
        let ftsUnitHits: [FTS5UnitSearchHit]
        if mode == .hybrid || mode == .ftsOnly {
            ftsUnitHits = (try? repository.searchFTS5Units(
                normalizedQueryTerms: queryTerms,
                rawQuery: trimmed,
                configuration: configuration
            )) ?? []
        } else {
            ftsUnitHits = []
        }
        let ftsSearchMs = (CFAbsoluteTimeGetCurrent() - ftsStart) * 1000.0

        // 4. ベクター検索実行（上位 100 検索単位）(§8, §9.1 #5, §9.2)
        let vecStart = CFAbsoluteTimeGetCurrent()
        let vectorUnitHits: [VectorSearchHit]
        if mode == .hybrid || mode == .vectorOnly {
            vectorUnitHits = (try? repository.vectorStore.searchSimilarUnits(
                queryVector: queryVector,
                embeddingModelId: embeddingAdapter.model.id,
                limit: configuration.vectorCandidateLimit
            )) ?? []
        } else {
            vectorUnitHits = []
        }
        let vectorSearchMs = (CFAbsoluteTimeGetCurrent() - vecStart) * 1000.0

        // 5. ドキュメント単位への集約 & RRF 統合 (§9.3, §10)
        let rrfStart = CFAbsoluteTimeGetCurrent()
        let readyDocs = (try? repository.fetchAllDocuments(onlyReady: true)) ?? []
        var docMap: [String: IndexedDocumentRecord] = [:]
        for d in readyDocs {
            docMap[d.id] = d
        }

        // 各検索単位をドキュメント単位に集約（長い文書がチャンク数の多さだけで過剰評価されるのを防止 §9.3, §16.2 #4）
        struct AggregatedDocCandidate {
            var documentId: String
            var bestFTSUnit: FTS5UnitSearchHit?
            var bestVectorUnit: VectorSearchHit?
            var ftsDocRank: Int?
            var vectorDocRank: Int?
            var matchedChunkIds: Set<String> = []
        }

        var candidatesByDocId: [String: AggregatedDocCandidate] = [:]

        // FTS5 の検索単位順位からドキュメント単位の順位 (1, 2, 3...) を決定
        var currentFTSDocRank = 0
        for hit in ftsUnitHits {
            let docId = hit.searchUnit.documentId
            guard docMap[docId] != nil else { continue }
            if candidatesByDocId[docId] == nil {
                candidatesByDocId[docId] = AggregatedDocCandidate(documentId: docId)
            }
            if candidatesByDocId[docId]?.bestFTSUnit == nil {
                currentFTSDocRank += 1
                candidatesByDocId[docId]?.bestFTSUnit = hit
                candidatesByDocId[docId]?.ftsDocRank = currentFTSDocRank
            } else if hit.searchUnit.unitType == .chunk,
                      candidatesByDocId[docId]?.bestFTSUnit?.searchUnit.unitType == .document {
                // 代表チャンク位置特定のために最良チャンクも記録
                if let cid = hit.searchUnit.chunkId {
                    candidatesByDocId[docId]?.matchedChunkIds.insert(cid)
                }
            }
            if let cid = hit.searchUnit.chunkId {
                candidatesByDocId[docId]?.matchedChunkIds.insert(cid)
            }
        }

        // ベクター検索の検索単位順位からドキュメント単位の順位 (1, 2, 3...) を決定
        var currentVecDocRank = 0
        for hit in vectorUnitHits {
            let docId = hit.searchUnit.documentId
            guard docMap[docId] != nil else { continue }
            if candidatesByDocId[docId] == nil {
                candidatesByDocId[docId] = AggregatedDocCandidate(documentId: docId)
            }
            if candidatesByDocId[docId]?.bestVectorUnit == nil {
                currentVecDocRank += 1
                candidatesByDocId[docId]?.bestVectorUnit = hit
                candidatesByDocId[docId]?.vectorDocRank = currentVecDocRank
            }
            if let cid = hit.searchUnit.chunkId {
                candidatesByDocId[docId]?.matchedChunkIds.insert(cid)
            }
        }

        let k = max(1.0, configuration.rrfK)
        let now = Date()
        var finalResults: [DocumentSearchResult] = []

        for (docId, cand) in candidatesByDocId {
            guard let doc = docMap[docId] else { continue }

            // 構造化メタデータフィルタ (§9.4)
            if let reqType = filter.documentType, doc.type != reqType {
                continue
            }
            if let after = filter.occurredAfter {
                let refDate = doc.occurredAt ?? doc.createdAt
                if refDate < after { continue }
            }
            if let before = filter.occurredBefore {
                let refDate = doc.occurredAt ?? doc.createdAt
                if refDate > before { continue }
            }
            if let participant = filter.participantQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
               !participant.isEmpty {
                let matchesParticipant = doc.participants.contains { $0.localizedCaseInsensitiveContains(participant) }
                    || doc.summary.localizedCaseInsensitiveContains(participant)
                if !matchesParticipant { continue }
            }

            // プロジェクト範囲フィルタ（全体 / プロジェクト優先 / プロジェクト限定）
            let belongsToTargetProject = filter.targetProjectId.map { doc.projectIds.contains($0) } ?? false
            if filter.scopeMode == .projectExclusive && !belongsToTargetProject {
                continue
            }

            // ドキュメントのチャンク一覧を取得して最良チャンクを特定
            let chunks = (try? repository.fetchDocumentChunks(documentId: docId)) ?? []
            let bestChunk = selectBestChunk(
                chunks: chunks,
                ftsUnit: cand.bestFTSUnit?.searchUnit,
                vecUnit: cand.bestVectorUnit,
                matchedChunkIds: cand.matchedChunkIds,
                queryTerms: queryTerms,
                querySignals: querySignals
            )

            // §9.3 RRF（Reciprocal Rank Fusion）基本スコア計算: `score = Σ (weight / (k + rank))`
            var rrfScore = 0.0
            if let fRank = cand.ftsDocRank, (mode == .hybrid || mode == .ftsOnly) {
                rrfScore += configuration.ftsRRFWeight / (k + Double(fRank))
            }
            if let vRank = cand.vectorDocRank, (mode == .hybrid || mode == .vectorOnly) {
                rrfScore += configuration.vectorRRFWeight / (k + Double(vRank))
            }

            // FTS とベクターの両方で上位ヒットした場合の相乗効果と意味的・語彙的整合性評価
            var combinedScore = rrfScore

            if mode == .hybrid || mode == .vectorOnly {
                if let cosSim = cand.bestVectorUnit?.cosineSimilarity {
                    combinedScore += cosSim * 0.012
                }
            }

            // §1.1, §6.3, §16.3 意味の区別（肯定/否定、決定/検討、明るい/暗い、予定/完了、重大/軽微）の厳密評価
            let targetTextForPolarity = "\(doc.title)\n\(bestChunk?.text ?? "")\n\(doc.summary)"
            let docSignals = textAnalyzer.extractSemanticSignals(in: targetTextForPolarity)
            let polarityAdjustment = Self.evaluateSemanticDistinctionAdjustment(
                querySignals: querySignals,
                docSignals: docSignals,
                rawQuery: trimmed,
                targetText: targetTextForPolarity
            )
            combinedScore += polarityAdjustment

            // クエリ内に人名・固有名詞や日時ヒント（「先月」「田中さん」等）が含まれる場合の整合ブースト
            let lowerTarget = targetTextForPolarity.lowercased()
            let nonMarkerQueryTerms = queryTerms.filter { !$0.hasPrefix("__") && $0.count >= 2 }
            var matchedKwList: [String] = []
            for qt in nonMarkerQueryTerms where lowerTarget.contains(qt) {
                matchedKwList.append(qt)
            }
            if !nonMarkerQueryTerms.isEmpty {
                let coverage = Double(matchedKwList.count) / Double(nonMarkerQueryTerms.count)
                combinedScore += coverage * 0.006
            }

            // プロジェクト優先検索時の鮮度付きブースト
            if filter.scopeMode == .projectPriority && belongsToTargetProject {
                let ageDays = max(0.0, now.timeIntervalSince(doc.updatedAt) / 86400.0)
                let recency = max(0.2, 1.0 / (1.0 + ageDays / 30.0))
                combinedScore += 0.004 * recency
            }

            let contentRec = try? repository.fetchDocumentContent(documentId: docId)
            let isAccessible = contentRec?.isSourceAccessible ?? true

            let snippetText: String
            if let bestChunk {
                snippetText = Self.buildSnippet(from: bestChunk.text, queryTerms: nonMarkerQueryTerms)
            } else {
                snippetText = doc.summary
            }

            finalResults.append(DocumentSearchResult(
                documentId: doc.id,
                title: doc.title,
                documentType: doc.type,
                sourceType: doc.sourceType,
                sourceURI: doc.sourceURI,
                createdAt: doc.createdAt,
                updatedAt: doc.updatedAt,
                occurredAt: doc.occurredAt,
                summary: doc.summary,
                snippet: snippetText,
                bestChunkId: bestChunk?.id,
                bestChunkIndex: bestChunk?.chunkIndex,
                startOffset: bestChunk?.startOffset,
                endOffset: bestChunk?.endOffset,
                startTimeMs: bestChunk?.startTimeMs,
                endTimeMs: bestChunk?.endTimeMs,
                combinedScore: combinedScore,
                rrfScore: rrfScore,
                ftsRank: cand.ftsDocRank,
                vectorRank: cand.vectorDocRank,
                bm25RawScore: cand.bestFTSUnit?.bm25RawScore,
                cosineSimilarity: cand.bestVectorUnit?.cosineSimilarity,
                matchedKeywords: matchedKwList,
                projectIds: doc.projectIds,
                participants: doc.participants,
                isSourceAccessible: isAccessible
            ))
        }

        let sorted = finalResults.sorted { a, b in
            if abs(a.combinedScore - b.combinedScore) > 1e-9 {
                return a.combinedScore > b.combinedScore
            }
            return (a.occurredAt ?? a.updatedAt) > (b.occurredAt ?? b.updatedAt)
        }

        let maxCount = limit ?? configuration.finalDocumentLimit
        let limited = Array(sorted.prefix(maxCount))

        let rrfFusionMs = (CFAbsoluteTimeGetCurrent() - rrfStart) * 1000.0
        let totalMs = (CFAbsoluteTimeGetCurrent() - totalStart) * 1000.0

        self.lastSearchTiming = SearchTimingMetrics(
            queryAnalysisMs: queryAnalysisMs,
            queryEmbeddingMs: queryEmbeddingMs,
            ftsSearchMs: ftsSearchMs,
            vectorSearchMs: vectorSearchMs,
            rrfFusionMs: rrfFusionMs,
            totalSearchMs: totalMs
        )

        return limited
    }

    // MARK: - §1.1, §6.3, §16.3 意味の区別（極性・状態一致ブースト＆相反ペナルティ）

    public static func evaluateSemanticDistinctionAdjustment(
        querySignals: SemanticPolaritySignals,
        docSignals: SemanticPolaritySignals,
        rawQuery: String,
        targetText: String
    ) -> Double {
        var delta = 0.0

        // 1. 採用（肯定） vs 不採用・見送り（否定） (§16.3 #1)
        if querySignals.hasAffirmativeAdoption && !querySignals.hasNegativeRejection {
            if docSignals.hasAffirmativeAdoption && !docSignals.hasNegativeRejection {
                delta += 0.015
            } else if docSignals.hasNegativeRejection && !docSignals.hasAffirmativeAdoption {
                delta -= 0.025
            }
        } else if querySignals.hasNegativeRejection && !querySignals.hasAffirmativeAdoption {
            if docSignals.hasNegativeRejection {
                delta += 0.015
            } else if docSignals.hasAffirmativeAdoption && !docSignals.hasNegativeRejection {
                delta -= 0.025
            }
        }

        // 2. 決定事項（確定） vs 提案・検討中（未確定） (§16.3 #2)
        if querySignals.hasConfirmedDecision && !querySignals.hasProposalOrConsideration {
            if docSignals.hasConfirmedDecision {
                delta += 0.012
            } else if docSignals.hasProposalOrConsideration && !docSignals.hasConfirmedDecision {
                delta -= 0.020
            }
        } else if querySignals.hasProposalOrConsideration && !querySignals.hasConfirmedDecision {
            if docSignals.hasProposalOrConsideration {
                delta += 0.012
            } else if docSignals.hasConfirmedDecision && !docSignals.hasProposalOrConsideration {
                delta -= 0.018
            }
        }

        // 3. 明るい vs 暗い (§16.3 #3)
        if querySignals.hasBrightAttribute && !querySignals.hasDarkAttribute {
            if docSignals.hasBrightAttribute {
                delta += 0.015
            } else if docSignals.hasDarkAttribute && !docSignals.hasBrightAttribute {
                delta -= 0.025
            }
        } else if querySignals.hasDarkAttribute && !querySignals.hasBrightAttribute {
            if docSignals.hasDarkAttribute {
                delta += 0.015
            } else if docSignals.hasBrightAttribute && !docSignals.hasDarkAttribute {
                delta -= 0.025
            }
        }

        // 4. 改善予定 vs 改善完了 (§16.3 #4)
        if querySignals.hasPlannedStatus && !querySignals.hasCompletedStatus {
            if docSignals.hasPlannedStatus {
                delta += 0.015
            } else if docSignals.hasCompletedStatus && !docSignals.hasPlannedStatus {
                delta -= 0.025
            }
        } else if querySignals.hasCompletedStatus && !querySignals.hasPlannedStatus {
            if docSignals.hasCompletedStatus {
                delta += 0.015
            } else if docSignals.hasPlannedStatus && !docSignals.hasCompletedStatus {
                delta -= 0.025
            }
        }

        // 5. 重大な障害 vs 軽微な障害 (§16.3 #5)
        if querySignals.hasCriticalSeverity && !querySignals.hasMinorSeverity {
            if docSignals.hasCriticalSeverity {
                delta += 0.015
            } else if docSignals.hasMinorSeverity && !docSignals.hasCriticalSeverity {
                delta -= 0.025
            }
        } else if querySignals.hasMinorSeverity && !querySignals.hasCriticalSeverity {
            if docSignals.hasMinorSeverity {
                delta += 0.015
            } else if docSignals.hasCriticalSeverity && !docSignals.hasMinorSeverity {
                delta -= 0.025
            }
        }

        return delta
    }

    // MARK: - Best Chunk Selection & Snippet Builder

    private func selectBestChunk(
        chunks: [DocumentChunkRecord],
        ftsUnit: SearchUnitRecord?,
        vecUnit: VectorSearchHit?,
        matchedChunkIds: Set<String>,
        queryTerms: [String],
        querySignals: SemanticPolaritySignals
    ) -> DocumentChunkRecord? {
        guard !chunks.isEmpty else { return nil }
        if chunks.count == 1 { return chunks[0] }

        // FTS または Vector で直接チャンクが1位ヒットしていればそれを優先候補にする
        let directFTSChunkId = ftsUnit?.chunkId
        let directVecChunkId = vecUnit?.searchUnit.chunkId

        let cleanTerms = queryTerms.filter { !$0.hasPrefix("__") && $0.count >= 2 }
        var bestScore = -Double.infinity
        var chosen = chunks[0]

        for chunk in chunks {
            var score = 0.0
            if chunk.id == directFTSChunkId { score += 5.0 }
            if chunk.id == directVecChunkId { score += 4.5 }
            if matchedChunkIds.contains(chunk.id) { score += 2.0 }

            let lower = chunk.text.lowercased()
            for term in cleanTerms where lower.contains(term) {
                score += 1.5
            }

            let cSignals = textAnalyzer.extractSemanticSignals(in: chunk.text)
            score += Self.evaluateSemanticDistinctionAdjustment(
                querySignals: querySignals,
                docSignals: cSignals,
                rawQuery: "",
                targetText: chunk.text
            ) * 100.0

            if score > bestScore {
                bestScore = score
                chosen = chunk
            }
        }
        return chosen
    }

    private static func buildSnippet(from chunkText: String, queryTerms: [String]) -> String {
        let trimmed = chunkText
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 160 else { return trimmed }

        let lower = trimmed.lowercased()
        for term in queryTerms {
            if let range = lower.range(of: term) {
                let matchIndex = lower.distance(from: lower.startIndex, to: range.lowerBound)
                let chars = Array(trimmed)
                let start = max(0, matchIndex - 35)
                let end = min(chars.count, start + 150)
                let prefix = start > 0 ? "…" : ""
                let suffix = end < chars.count ? "…" : ""
                return prefix + String(chars[start..<end]) + suffix
            }
        }
        return String(trimmed.prefix(150)) + "…"
    }

    // MARK: - §16.5 検索品質評価スイート（50件以上の検索クエリと正解文書で FTS5 / ベクター / ハイブリッドを比較）

    public static func runSearchQualityEvaluationSuite(
        embeddingModel: AIModel? = nil
    ) throws -> SearchQualityEvaluationReport {
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("eval-hybrid-search-\(UUID().uuidString).sqlite3").path
        defer {
            try? FileManager.default.removeItem(atPath: tempPath)
        }

        let db = try LocalDatabase(databasePath: tempPath)
        let repo = DocumentRepository(database: db)
        let analyzer = NaturalLanguageTextAnalyzer()
        let indexMgr = IndexManager(repository: repo, textAnalyzer: analyzer)
        let hybridSvc = HybridSearchService(repository: repo, indexManager: indexMgr, textAnalyzer: analyzer)

        let model = embeddingModel ?? AIModel(
            id: "emb-multilingual-e5-small-384d",
            name: "Multilingual-E5-Small 384d",
            category: .embedding,
            version: "1.1.0",
            downloadState: .installed,
            runtime: .mlxLLM,
            requiredMemoryMB: 280,
            supportsJapanese: true,
            streamingCapability: .batchOnly,
            supportsCustomVocabulary: false,
            diskSizeMB: 240,
            endpointOrPath: "intfloat/multilingual-e5-small#384d",
            license: "MIT",
            notes: "384d"
        )
        let adapter = LocalEmbeddingAdapter(model: model)

        // 評価用コーパス文書（20件：議事録・技術仕様書・障害報告・企画提案・意味対比ペアを含む）
        let corpus: [(id: String, title: String, type: IndexedDocumentType, participants: [String], text: String)] = [
            (
                "doc-firebase-auth-meeting",
                "認証基盤リニューアル検討会議",
                .meeting,
                ["佐藤", "鈴木"],
                """
                # 認証基盤リニューアル検討会議
                [00:10] 佐藤: 本日はモバイルとWebのログイン基盤として Firebase Auth の認証方式をどのように構成するか議論します。
                [01:20] 鈴木: IDトークンの検証とセッション管理、リフレッシュトークンの有効期限について確認しました。決定事項として、Firebaseの認証方式ではマルチファクタ認証を有効化することになりました。
                """
            ),
            (
                "doc-apple-login-adopted",
                "ソーシャルログイン選定・Appleログイン採用決定議事録",
                .meeting,
                ["山田", "高橋"],
                """
                # ソーシャルログイン選定会議
                [00:15] 山田: iOSアプリ審査ガイドラインへの準拠とユーザーのメールアドレス非公開保護（プライバシー保護）が決め手となり、Sign in with Apple（Appleログイン）を採用することになった。
                [02:10] 高橋: これによりAppleログインを採用した理由として、セキュリティと審査要件の両立が明確に決定事項として合意された。
                """
            ),
            (
                "doc-apple-login-rejected",
                "レガシー社内ツール認証検討メモ（Appleログイン見送り）",
                .document,
                ["山田"],
                """
                # レガシー社内ツール認証検討メモ
                社内Windows専用管理画面について検討したが、利用端末が全てWindows PCであるため、今回はAppleログインは採用しなかった（導入を見送った）。代わりに社内SAML SSOを継続利用する。
                """
            ),
            (
                "doc-performance-optimization",
                "アプリ起動速度・クエリ応答時間チューニング資料",
                .document,
                ["伊藤", "渡辺"],
                """
                # アプリ起動速度・クエリ応答時間チューニング資料
                画面遷移時のレイテンシとデータベース検索のボトルネックを調査し、キャッシュ層の導入とインデックス設計の見直しによりレスポンスを30%高速化した。メモリ消費量も削減し、パフォーマンス改善を実現した。
                """
            ),
            (
                "doc-tanaka-feature-proposal",
                "先月のプロダクト企画定例（田中さんの新機能アイデア）",
                .meeting,
                ["田中", "佐藤"],
                """
                # 先月のプロダクト企画定例
                [03:00] 田中: 先月のユーザーヒアリングを踏まえ、田中さんが会議中の発言から自動でキーボードショートカット辞書とタグを生成する機能を提案した。現在はプロトタイプとして提案された段階で、来月検討を進める。
                """
            ),
            (
                "doc-tanaka-feature-decided",
                "プロダクト開発委員会（音声エクスポート機能の正式決定）",
                .meeting,
                ["中村", "小林"],
                """
                # プロダクト開発委員会
                [05:10] 中村: 音声ファイルの一括Markdownエクスポート機能は本日の会議で正式に決定された。来週リリースに向けて実装を開始することが確定した。
                """
            ),
            (
                "doc-design-bright-meeting",
                "UIリニューアル・カラーテーマ検討会議（明るい配色案）",
                .meeting,
                ["加藤", "吉田"],
                """
                # UIリニューアル・カラーテーマ検討会議
                [01:45] 加藤: 昼間のオフィス環境での視認性を高めるため、背景の明度を上げてデザインを明るくするという意見が出た。白基調のライトモードを標準テーマとして採用する方針で議論した。
                """
            ),
            (
                "doc-design-dark-meeting",
                "夜間作業向けターミナル画面デザイン検討（暗い配色案）",
                .meeting,
                ["加藤", "松本"],
                """
                # 夜間作業向け画面デザイン検討
                [02:00] 松本: 長時間のコーディングで目の負担を減らすため、背景を黒基調にしてデザインを暗くするダークモード専用テーマとした。明るい配色は採用しない。
                """
            ),
            (
                "doc-cpp-audio-dsp",
                "C++ オーディオDSPエンジン実装仕様書",
                .document,
                ["井上"],
                """
                # C++ オーディオDSPエンジン実装仕様書
                リアルタイム音声のノイズ除去とリサンプリング処理は C++ (SIMD命令) で実装し、SwiftからC++インターフェースを直接呼び出すことで10ミリ秒以下の低遅延を実現する。
                """
            ),
            (
                "doc-c-legacy-header",
                "C言語システムコールラッパー仕様書",
                .document,
                ["井上"],
                """
                # C言語システムコールラッパー仕様書
                POSIXファイルディスクリプタ監視のための純粋なC言語ヘッダ定義。
                """
            ),
            (
                "doc-oauth2-spec",
                "OAuth2 認可コードフローとPKCE実装ガイド",
                .document,
                ["木村"],
                """
                # OAuth2 認可コードフローとPKCE実装ガイド
                外部API連携では OAuth2 および PKCE 拡張を用いてアクセストークンを安全に取得する。クライアントシークレットを端末内に保持しない設計とする。
                """
            ),
            (
                "doc-swiftui-workspace",
                "SwiftUI マルチカラムワークスペース画面設計書",
                .document,
                ["林", "斎藤"],
                """
                # SwiftUI マルチカラムワークスペース画面設計書
                macOS 15 向けの NavigationSplitView と Observation を活用し、SwiftUI でリアルタイム文字起こしと議事録エディタを1ウィンドウ表示する。
                """
            ),
            (
                "doc-sqlite-fts5-vec",
                "SQLite FTS5 & sqlite-vec ハイブリッド検索アーキテクチャ",
                .document,
                ["山本"],
                """
                # SQLite FTS5 & sqlite-vec ハイブリッド検索アーキテクチャ
                全文検索には SQLite FTS5 の External Content テーブルと BM25 重み付けを使用し、ベクター検索には sqlite-vec と 384次元 Embedding を併用して RRF (k=60) でランキング統合する。
                """
            ),
            (
                "doc-progress-planned",
                "検索インデックスメモリ最適化（来月改善予定）",
                .document,
                ["山本"],
                """
                # 検索インデックスメモリ最適化計画
                Int8量子化によるベクター容量削減は来月改善予定のバックログ項目であり、現在はまだ計画中（対応予定）である。
                """
            ),
            (
                "doc-progress-completed",
                "検索インデックス差分更新バグ修正（改善完了報告）",
                .document,
                ["山本"],
                """
                # 検索インデックス差分更新バグ修正報告
                チャンクハッシュ比較による差分更新と不要ベクター削除の高速化は先週すでに改善完了（対応完了）しており、本番環境へ適用済みである。
                """
            ),
            (
                "doc-incident-critical",
                "本番決済API 重大な障害ポストモーテム (Sev1)",
                .document,
                ["佐々木"],
                """
                # 本番決済API 重大な障害ポストモーテム
                データベース接続プール枯渇により全ユーザーの決済処理が2時間全面停止する重大な障害（クリティカルインシデント）が発生した。緊急パッチで復旧した。
                """
            ),
            (
                "doc-incident-minor",
                "管理画面ツールチップ表示ずれ 軽微な障害報告 (Sev3)",
                .document,
                ["佐々木"],
                """
                # 管理画面ツールチップ表示ずれ 軽微な障害報告
                設定画面の一部アイコンでツールチップが2pxずれる軽微な障害が確認された。機能への影響範囲は限定的でマイナーな事象である。
                """
            ),
            (
                "doc-qwen-asr-benchmark",
                "Qwen3-ASR 0.6B と WhisperKit の日本語音声認識ベンチマーク",
                .document,
                ["清水"],
                """
                # Qwen3-ASR 0.6B と WhisperKit の日本語音声認識ベンチマーク
                Apple Silicon M3 環境において Qwen3-ASR 0.6B と Whisper Large v3 Turbo の文字誤り率 (CER) とリアルタイム係数 (RTF) を比較測定した。
                """
            ),
            (
                "doc-multi-topic-long-meeting",
                "Q4全社エンジニアリング定例会議（長文・複数議題）",
                .meeting,
                ["佐藤", "鈴木", "高橋", "田中"],
                """
                # 第1部：オフィス移転と備品発注について
                来期のオフィスレイアウト変更とモニター発注台数の確認を行った。総務チームが来週見積もりを取得する。

                # 第2部：新卒採用面接のスケジュール調整
                人事部と連携し、秋のインターンシップ選考日程と面接官アサイン表を確定した。

                # 第3部：WebAssemblyプラグインサンドボックスの技術検証
                ブラウザ拡張およびデスクトップアプリ内でサードパーティスクリプトを安全に隔離実行するため、WebAssembly (Wasm) ランタイムによるプラグインサンドボックス機構を導入する技術検証を実施した。
                """
            ),
            (
                "doc-security-privacy-policy",
                "ローカルAIデータ保護・オフラインプライバシー設計指針",
                .document,
                ["橋本"],
                """
                # ローカルAIデータ保護・オフラインプライバシー設計指針
                録音された会議音声や機密ドキュメントはクラウドサーバーへ一切アップロードせず、端末内の暗号化ストレージとローカルLLMのみで完結処理する。
                """
            )
        ]

        for item in corpus {
            _ = try indexMgr.indexDocument(
                id: item.id,
                title: item.title,
                rawText: item.text,
                type: item.type,
                sourceType: .local,
                sourceURI: "local://\(item.id)",
                participants: item.participants,
                embeddingAdapter: adapter
            )
        }

        // §16.5 52件の評価クエリ（§1.1 想定検索、§16.1 キーワード検索、§16.2 意味検索、§16.3 意味の区別を網羅）
        let queries: [SearchEvaluationQueryCase] = [
            // --- A. §1.1 仕様書記載の想定検索 (5件) ---
            SearchEvaluationQueryCase(id: "Q01", category: "§1.1 想定検索", query: "Firebaseの認証方式について議論した会議", expectedDocumentId: "doc-firebase-auth-meeting"),
            SearchEvaluationQueryCase(id: "Q02", category: "§1.1 想定検索", query: "Appleログインを採用することになった理由", expectedDocumentId: "doc-apple-login-adopted", forbiddenTop1DocumentId: "doc-apple-login-rejected"),
            SearchEvaluationQueryCase(id: "Q03", category: "§1.1 想定検索", query: "パフォーマンス改善について話した資料", expectedDocumentId: "doc-performance-optimization"),
            SearchEvaluationQueryCase(id: "Q04", category: "§1.1 想定検索", query: "先月、田中さんが提案した機能", expectedDocumentId: "doc-tanaka-feature-proposal", forbiddenTop1DocumentId: "doc-tanaka-feature-decided"),
            SearchEvaluationQueryCase(id: "Q05", category: "§1.1 想定検索", query: "デザインを明るくするという意見が出た会議", expectedDocumentId: "doc-design-bright-meeting", forbiddenTop1DocumentId: "doc-design-dark-meeting"),

            // --- B. §16.1 キーワード検索：固有名詞・技術用語・記号・2文字語・表記ゆれ (17件) ---
            SearchEvaluationQueryCase(id: "Q06", category: "§16.1 記号技術用語", query: "C++ オーディオDSP", expectedDocumentId: "doc-cpp-audio-dsp", forbiddenTop1DocumentId: "doc-c-legacy-header"),
            SearchEvaluationQueryCase(id: "Q07", category: "§16.1 記号技術用語", query: "C++ 低遅延 リサンプリング", expectedDocumentId: "doc-cpp-audio-dsp", forbiddenTop1DocumentId: "doc-c-legacy-header"),
            SearchEvaluationQueryCase(id: "Q08", category: "§16.1 記号技術用語", query: "OAuth2 PKCE アクセストークン", expectedDocumentId: "doc-oauth2-spec"),
            SearchEvaluationQueryCase(id: "Q09", category: "§16.1 記号技術用語", query: "SwiftUI NavigationSplitView ワークスペース", expectedDocumentId: "doc-swiftui-workspace"),
            SearchEvaluationQueryCase(id: "Q10", category: "§16.1 記号技術用語", query: "sqlite-vec FTS5 BM25 RRF", expectedDocumentId: "doc-sqlite-fts5-vec"),
            SearchEvaluationQueryCase(id: "Q11", category: "§16.1 記号技術用語", query: "Qwen3-ASR 0.6B WhisperKit CER", expectedDocumentId: "doc-qwen-asr-benchmark"),
            SearchEvaluationQueryCase(id: "Q12", category: "§16.1 表記ゆれ", query: "モバイルのサインイン基盤とマルチファクタ認証", expectedDocumentId: "doc-firebase-auth-meeting"),
            SearchEvaluationQueryCase(id: "Q13", category: "§16.1 表記ゆれ", query: "Sign in with Apple の導入理由", expectedDocumentId: "doc-apple-login-adopted"),
            SearchEvaluationQueryCase(id: "Q14", category: "§16.1 日本語2文字語", query: "田中 ショートカット", expectedDocumentId: "doc-tanaka-feature-proposal"),
            SearchEvaluationQueryCase(id: "Q15", category: "§16.1 日本語2文字語", query: "認証 リフレッシュトークン", expectedDocumentId: "doc-firebase-auth-meeting"),
            SearchEvaluationQueryCase(id: "Q16", category: "§16.1 日本語2文字語", query: "決済 停止", expectedDocumentId: "doc-incident-critical"),
            SearchEvaluationQueryCase(id: "Q17", category: "§16.1 数値・単位保護", query: "レスポンスを30%高速化した資料", expectedDocumentId: "doc-performance-optimization"),
            SearchEvaluationQueryCase(id: "Q18", category: "§16.1 数値・単位保護", query: "10ミリ秒以下の低遅延", expectedDocumentId: "doc-cpp-audio-dsp"),
            SearchEvaluationQueryCase(id: "Q19", category: "§16.1 数値・単位保護", query: "384次元 Embedding", expectedDocumentId: "doc-sqlite-fts5-vec"),
            SearchEvaluationQueryCase(id: "Q20", category: "§16.1 固有名詞", query: "WebAssembly プラグインサンドボックス", expectedDocumentId: "doc-multi-topic-long-meeting"),
            SearchEvaluationQueryCase(id: "Q21", category: "§16.1 固有名詞", query: "POSIX ファイルディスクリプタ C言語", expectedDocumentId: "doc-c-legacy-header"),
            SearchEvaluationQueryCase(id: "Q22", category: "§16.1 形容詞検索", query: "白基調で視認性を高める明るいテーマ", expectedDocumentId: "doc-design-bright-meeting"),

            // --- C. §16.2 意味検索：語彙が一致しない自然言語クエリ・一部チャンク話題 (15件) ---
            SearchEvaluationQueryCase(id: "Q23", category: "§16.2 意味検索", query: "アプリの動作が遅い問題を解消して速度を上げたドキュメント", expectedDocumentId: "doc-performance-optimization"),
            SearchEvaluationQueryCase(id: "Q24", category: "§16.2 意味検索", query: "画面の色合いや見た目を白っぽく見やすくする相談", expectedDocumentId: "doc-design-bright-meeting"),
            SearchEvaluationQueryCase(id: "Q25", category: "§16.2 意味検索", query: "夜間作業で目が疲れないように黒ベースの画面にする話", expectedDocumentId: "doc-design-dark-meeting"),
            SearchEvaluationQueryCase(id: "Q26", category: "§16.2 意味検索", query: "外部サーバーに機密データや音声を送らず端末内で処理する方針", expectedDocumentId: "doc-security-privacy-policy"),
            SearchEvaluationQueryCase(id: "Q27", category: "§16.2 意味検索", query: "iOSの審査対策とメールアドレス保護のために決めたログイン方法", expectedDocumentId: "doc-apple-login-adopted"),
            SearchEvaluationQueryCase(id: "Q28", category: "§16.2 意味検索", query: "サードパーティのスクリプトを隔離して安全に動かすWasmの検証", expectedDocumentId: "doc-multi-topic-long-meeting"),
            SearchEvaluationQueryCase(id: "Q29", category: "§16.2 意味検索", query: "音声認識モデルの文字誤り率と処理速度の比較テスト", expectedDocumentId: "doc-qwen-asr-benchmark"),
            SearchEvaluationQueryCase(id: "Q30", category: "§16.2 意味検索", query: "全文検索とベクトル検索のランキングを統合する仕組み", expectedDocumentId: "doc-sqlite-fts5-vec"),
            SearchEvaluationQueryCase(id: "Q31", category: "§16.2 意味検索", query: "クライアントシークレットを持たずに外部APIの認可を行う手順", expectedDocumentId: "doc-oauth2-spec"),
            SearchEvaluationQueryCase(id: "Q32", category: "§16.2 意味検索", query: "発言内容からタグやショートカット辞書を自動生成するアイデア", expectedDocumentId: "doc-tanaka-feature-proposal"),
            SearchEvaluationQueryCase(id: "Q33", category: "§16.2 意味検索", query: "音声ファイルをまとめてMarkdown形式で出力する決定", expectedDocumentId: "doc-tanaka-feature-decided"),
            SearchEvaluationQueryCase(id: "Q34", category: "§16.2 意味検索", query: "DBコネクション枯渇でサービスが全面停止したトラブルの原因", expectedDocumentId: "doc-incident-critical"),
            SearchEvaluationQueryCase(id: "Q35", category: "§16.2 意味検索", query: "アイコンのツールチップが少しだけずれる小さな不具合", expectedDocumentId: "doc-incident-minor"),
            SearchEvaluationQueryCase(id: "Q36", category: "§16.2 意味検索", query: "macOS向けの分割ナビゲーション画面とリアルタイムエディタUI", expectedDocumentId: "doc-swiftui-workspace"),
            SearchEvaluationQueryCase(id: "Q37", category: "§16.2 意味検索", query: "チャンクのハッシュ値を比較して変更分だけインデックス更新する修正", expectedDocumentId: "doc-progress-completed"),

            // --- D. §16.3 意味の区別：肯定/否定、決定/提案、明/暗、予定/完了、重大/軽微 (15件) ---
            SearchEvaluationQueryCase(id: "Q38", category: "§16.3 肯定vs否定", query: "Appleログインを採用した会議", expectedDocumentId: "doc-apple-login-adopted", forbiddenTop1DocumentId: "doc-apple-login-rejected"),
            SearchEvaluationQueryCase(id: "Q39", category: "§16.3 肯定vs否定", query: "Appleログインを採用しなかった（見送った）資料", expectedDocumentId: "doc-apple-login-rejected", forbiddenTop1DocumentId: "doc-apple-login-adopted"),
            SearchEvaluationQueryCase(id: "Q40", category: "§16.3 肯定vs否定", query: "Windows専用のためAppleログイン導入を見送ったメモ", expectedDocumentId: "doc-apple-login-rejected", forbiddenTop1DocumentId: "doc-apple-login-adopted"),
            SearchEvaluationQueryCase(id: "Q41", category: "§16.3 提案vs決定", query: "新機能が提案された（検討中の）会議", expectedDocumentId: "doc-tanaka-feature-proposal", forbiddenTop1DocumentId: "doc-tanaka-feature-decided"),
            SearchEvaluationQueryCase(id: "Q42", category: "§16.3 提案vs決定", query: "エクスポート機能の実装が正式に決定された会議", expectedDocumentId: "doc-tanaka-feature-decided", forbiddenTop1DocumentId: "doc-tanaka-feature-proposal"),
            SearchEvaluationQueryCase(id: "Q43", category: "§16.3 明るいvs暗い", query: "画面デザインを明るくするライトモードの会議", expectedDocumentId: "doc-design-bright-meeting", forbiddenTop1DocumentId: "doc-design-dark-meeting"),
            SearchEvaluationQueryCase(id: "Q44", category: "§16.3 明るいvs暗い", query: "画面デザインを暗くするダークモードの会議", expectedDocumentId: "doc-design-dark-meeting", forbiddenTop1DocumentId: "doc-design-bright-meeting"),
            SearchEvaluationQueryCase(id: "Q45", category: "§16.3 明るいvs暗い", query: "明るい配色は採用せず黒基調にしたデザイン", expectedDocumentId: "doc-design-dark-meeting", forbiddenTop1DocumentId: "doc-design-bright-meeting"),
            SearchEvaluationQueryCase(id: "Q46", category: "§16.3 予定vs完了", query: "検索インデックスのInt8量子化が来月改善予定の資料", expectedDocumentId: "doc-progress-planned", forbiddenTop1DocumentId: "doc-progress-completed"),
            SearchEvaluationQueryCase(id: "Q47", category: "§16.3 予定vs完了", query: "検索インデックスの差分更新がすでに改善完了した資料", expectedDocumentId: "doc-progress-completed", forbiddenTop1DocumentId: "doc-progress-planned"),
            SearchEvaluationQueryCase(id: "Q48", category: "§16.3 予定vs完了", query: "まだ計画中で今後対応予定のメモリ最適化", expectedDocumentId: "doc-progress-planned", forbiddenTop1DocumentId: "doc-progress-completed"),
            SearchEvaluationQueryCase(id: "Q49", category: "§16.3 予定vs完了", query: "先週対応完了し本番適用済みのインデックス修正", expectedDocumentId: "doc-progress-completed", forbiddenTop1DocumentId: "doc-progress-planned"),
            SearchEvaluationQueryCase(id: "Q50", category: "§16.3 重大vs軽微", query: "決済処理が全面停止した重大な障害の報告書", expectedDocumentId: "doc-incident-critical", forbiddenTop1DocumentId: "doc-incident-minor"),
            SearchEvaluationQueryCase(id: "Q51", category: "§16.3 重大vs軽微", query: "ツールチップがずれる軽微な障害の報告書", expectedDocumentId: "doc-incident-minor", forbiddenTop1DocumentId: "doc-incident-critical"),
            SearchEvaluationQueryCase(id: "Q52", category: "§16.3 重大vs軽微", query: "影響範囲が限定的なマイナーで軽微な障害", expectedDocumentId: "doc-incident-minor", forbiddenTop1DocumentId: "doc-incident-critical")
        ]

        func evaluate(mode: HybridSearchExecutionMode) -> SearchModeEvaluationMetrics {
            var hitsAt1 = 0
            var hitsAt5 = 0
            var reciprocalRankSum = 0.0
            var distinctionChecks = 0
            var distinctionPassed = 0
            var totalMs = 0.0

            for qCase in queries {
                let t0 = CFAbsoluteTimeGetCurrent()
                let results = hybridSvc.searchDocuments(
                    query: qCase.query,
                    mode: mode,
                    embeddingAdapter: adapter,
                    limit: 10
                )
                totalMs += (CFAbsoluteTimeGetCurrent() - t0) * 1000.0

                if let rankIdx = results.firstIndex(where: { $0.documentId == qCase.expectedDocumentId }) {
                    let rank = rankIdx + 1
                    if rank == 1 { hitsAt1 += 1 }
                    if rank <= 5 { hitsAt5 += 1 }
                    reciprocalRankSum += 1.0 / Double(rank)
                }

                if let forbidden = qCase.forbiddenTop1DocumentId {
                    distinctionChecks += 1
                    let topDocId = results.first?.documentId
                    if topDocId == qCase.expectedDocumentId && topDocId != forbidden {
                        distinctionPassed += 1
                    }
                }
            }

            let countD = Double(max(1, queries.count))
            let distAcc = distinctionChecks > 0 ? Double(distinctionPassed) / Double(distinctionChecks) : 1.0
            return SearchModeEvaluationMetrics(
                mode: mode,
                queryCount: queries.count,
                recallAt1: Double(hitsAt1) / countD,
                recallAt5: Double(hitsAt5) / countD,
                mrr: reciprocalRankSum / countD,
                semanticDistinctionAccuracy: distAcc,
                averageSearchMs: totalMs / countD
            )
        }

        let ftsMetrics = evaluate(mode: .ftsOnly)
        let vecMetrics = evaluate(mode: .vectorOnly)
        let hybridMetrics = evaluate(mode: .hybrid)
        let storage = repo.computeStorageMetrics(
            activeEmbeddingModelId: adapter.model.id,
            activeEmbeddingDimension: adapter.dimensions,
            lastIndexingDurationMs: indexMgr.lastIndexingDurationMs,
            lastSearchTiming: hybridSvc.lastSearchTiming
        )

        return SearchQualityEvaluationReport(
            totalQueries: queries.count,
            totalDocuments: corpus.count,
            ftsOnlyMetrics: ftsMetrics,
            vectorOnlyMetrics: vecMetrics,
            hybridMetrics: hybridMetrics,
            storageMetrics: storage
        )
    }
}
