import Foundation
import NaturalLanguage
import Observation

public struct LiveDiscussionDigest: Codable, Sendable, Equatable {
    public var currentTopic: String
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var unresolvedQuestions: [String]
    public var utteranceCount: Int
    public var summaryEngineName: String
    public var updatedAt: Date

    public init(
        currentTopic: String = "会議待機中（発話が始まると自動で論点を要約します）",
        keyPoints: [String] = [],
        decisions: [String] = [],
        actionItems: [ActionItem] = [],
        unresolvedQuestions: [String] = [],
        utteranceCount: Int = 0,
        summaryEngineName: String = "Apple Intelligence / Local LLM",
        updatedAt: Date = Date()
    ) {
        self.currentTopic = currentTopic
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.unresolvedQuestions = unresolvedQuestions
        self.utteranceCount = utteranceCount
        self.summaryEngineName = summaryEngineName
        self.updatedAt = updatedAt
    }
}

public enum SuggestedResourceKind: String, Codable, CaseIterable, Sendable {
    case document = "ローカル資料"
    case pastMeeting = "過去の議事録"
    case vocabulary = "専門用語辞書"

    public var systemImage: String {
        switch self {
        case .document: "doc.text.magnifyingglass"
        case .pastMeeting: "clock.badge.checkmark"
        case .vocabulary: "character.book.closed.fill"
        }
    }
}

public struct RelatedResourceSuggestion: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var kind: SuggestedResourceKind
    public var sourceId: UUID
    public var title: String
    public var subtitle: String
    public var matchedKeywords: [String]
    public var matchedReason: String
    public var snippet: String
    public var fullPreviewText: String
    public var relevanceScore: Double

    public init(
        id: UUID = UUID(),
        kind: SuggestedResourceKind,
        sourceId: UUID,
        title: String,
        subtitle: String,
        matchedKeywords: [String],
        matchedReason: String,
        snippet: String,
        fullPreviewText: String,
        relevanceScore: Double
    ) {
        self.id = id
        self.kind = kind
        self.sourceId = sourceId
        self.title = title
        self.subtitle = subtitle
        self.matchedKeywords = matchedKeywords
        self.matchedReason = matchedReason
        self.snippet = snippet
        self.fullPreviewText = fullPreviewText
        self.relevanceScore = relevanceScore
    }
}

/// 「会議のAIパートナー」コパイロットサービス
/// - リアルタイム文字起こしの進行に合わせて「議論のライブ要約（要点圧縮・挨拶除去・論点抽出）」と
///   「関連資料・過去議事録・専門用語の自動提案」を即時更新する
@Observable
@MainActor
public final class MeetingPartnerService {
    private let searchService: SearchService
    private let documentService: DocumentService
    private let llmService: LLMService
    private let projectService: ProjectService

    public private(set) var liveDigest: LiveDiscussionDigest = LiveDiscussionDigest()
    public private(set) var relatedSuggestions: [RelatedResourceSuggestion] = []
    public private(set) var isSummarizingWithLLM: Bool = false
    public var previewingSuggestion: RelatedResourceSuggestion?
    private var llmSummaryTask: Task<Void, Never>?

    public init(
        searchService: SearchService,
        documentService: DocumentService,
        llmService: LLMService,
        projectService: ProjectService
    ) {
        self.searchService = searchService
        self.documentService = documentService
        self.llmService = llmService
        self.projectService = projectService
    }

    /// 発話セグメント一覧から「リアルタイム議論要約」と「関連資料の自動提案」を更新する
    public func refreshCopilotContext(
        transcript: Transcript?,
        segments: [TranscriptSegment],
        activeProjectId: UUID?,
        llmModel: AIModel? = nil
    ) {
        guard !segments.isEmpty else {
            llmSummaryTask?.cancel()
            isSummarizingWithLLM = false
            self.liveDigest = LiveDiscussionDigest()
            self.relatedSuggestions = buildInitialProjectSuggestions(projectId: activeProjectId)
            return
        }

        // 1. 発話を文単位に分割し、挨拶・定型句を除いて構造化要約を生成
        var explicitTopics: [String] = []
        var keyPoints: [String] = []
        var decisions: [String] = []
        var actionItems: [ActionItem] = []
        var unresolved: [String] = []
        var seenSummaries: Set<String> = []

        for seg in segments {
            let formatted = LiveAudioStreamEngine.formatJapanesePunctuation(seg.correctedText)
            let sentences = Self.splitIntoSentences(formatted)
            let timeStr = LocalLLMAdapter.formatTimestamp(seg.startTimeSeconds)

            for rawSentence in sentences {
                let sentence = rawSentence.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sentence.isEmpty else { continue }

                // 挨拶・自己紹介・リンク案内等のメタ発話は要点リストからスキップ
                if Self.isGreetingOrMetaFiller(sentence) {
                    continue
                }

                let compressed = Self.compressSentenceToKeyPoint(sentence)
                guard !compressed.isEmpty, !seenSummaries.contains(compressed) else { continue }

                if sentence.contains("議題") || sentence.contains("テーマ") || sentence.contains("本題") {
                    explicitTopics.append(compressed)
                }

                if sentence.contains("決定") || sentence.contains("採用") || sentence.contains("方針") || sentence.contains("合意") || sentence.contains("こととします") {
                    seenSummaries.insert(compressed)
                    decisions.append("[\(timeStr)] \(compressed)")
                } else if sentence.contains("TODO") || sentence.contains("アクション") || sentence.contains("までに") || sentence.contains("実施します") || sentence.contains("対応します") {
                    seenSummaries.insert(compressed)
                    let assignee = LocalLLMAdapter.extractExplicitAssignee(from: sentence)
                    let due = LocalLLMAdapter.extractExplicitDueDate(from: sentence)
                    actionItems.append(
                        ActionItem(
                            title: compressed,
                            assignee: assignee,
                            dueDateText: due,
                            isCompleted: false,
                            sourceSegmentId: seg.id
                        )
                    )
                } else if sentence.contains("課題") || sentence.contains("未解決") || sentence.contains("検討中") || sentence.contains("保留") {
                    seenSummaries.insert(compressed)
                    unresolved.append("[\(timeStr)] \(compressed)")
                } else {
                    seenSummaries.insert(compressed)
                    keyPoints.append("[\(timeStr)] \(compressed)")
                }
            }
        }

        // もし発話が挨拶のみだった場合のフォールバック要約
        if keyPoints.isEmpty && decisions.isEmpty && actionItems.isEmpty, let lastSeg = segments.last {
            let fallbackSummary = Self.compressSentenceToKeyPoint(lastSeg.correctedText)
            let timeStr = LocalLLMAdapter.formatTimestamp(lastSeg.startTimeSeconds)
            keyPoints.append("[\(timeStr)] \(fallbackSummary)")
        }

        // 現在の論点・テーマ（長文の丸写しではなく、端的なトピック見出しを生成）
        let currentTopicHeadline = Self.buildConciseTopicHeadline(
            explicitTopics: explicitTopics,
            keyPoints: keyPoints,
            segments: segments
        )

        let initialDigest = LiveDiscussionDigest(
            currentTopic: currentTopicHeadline,
            keyPoints: Array(keyPoints.suffix(6)),
            decisions: decisions,
            actionItems: actionItems,
            unresolvedQuestions: unresolved,
            utteranceCount: segments.count,
            summaryEngineName: llmModel?.name ?? "Apple Intelligence / Local LLM",
            updatedAt: Date()
        )
        self.liveDigest = initialDigest

        // 2. 直近の発話内容から関連資料・過去議事録・用語を自動提案
        let recentText = segments.suffix(3).map(\.correctedText).joined(separator: " ")
        let allText = segments.map(\.correctedText).joined(separator: " ")
        self.relatedSuggestions = computeRelatedSuggestions(
            recentUtteranceText: recentText,
            fullTranscriptText: allText,
            currentTranscriptId: transcript?.id,
            activeProjectId: activeProjectId ?? transcript?.projectIds.first
        )

        // 3. 選択されたLLM（Apple Intelligence FoundationModels または Ollama / MLX ローカルLLM）による非同期AI要約を実行
        if let activeLLM = llmModel, !LocalLLMAdapter.isRunningUnderTestRunner {
            llmSummaryTask?.cancel()
            isSummarizingWithLLM = true
            let activeProject = projectService.project(for: activeProjectId)
            llmSummaryTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let adapter = LocalLLMAdapter(model: activeLLM)
                if let llmDigest = await adapter.summarizeLiveDiscussionWithLLM(
                    segments: segments,
                    project: activeProject,
                    fallbackDigest: initialDigest
                ), !Task.isCancelled {
                    self.liveDigest = llmDigest
                }
                if !Task.isCancelled {
                    self.isSummarizingWithLLM = false
                }
            }
        }
    }

    // MARK: - ローカル自然言語要約・要点圧縮ヘルパー

    /// テキストを文単位（「。」「！」「？」）に分割する
    public static func splitIntoSentences(_ text: String) -> [String] {
        let normalized = text
            .replacingOccurrences(of: "！", with: "。")
            .replacingOccurrences(of: "？", with: "。")
            .replacingOccurrences(of: "\n", with: "。")
        return normalized
            .split(separator: "。")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// 挨拶・チャンネル定型句・メタ発言かどうかを判定する
    public static func isGreetingOrMetaFiller(_ sentence: String) -> Bool {
        let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count <= 4 { return true }

        let pureFillerPatterns = [
            "ようこそ", "概要欄のリンク", "ぜひご覧ください", "チャンネル登録",
            "高評価", "早速見ていきましょう", "さっそく見ていきましょう",
            "お疲れ様です", "よろしくお願いします", "よろしくお願いいたします",
            "ありがとうございました", "では始めます"
        ]
        // 短めの自己紹介・挨拶文（「〜の太田です」「こんにちは〜」等）で実質トピックを含まないものを除外
        if pureFillerPatterns.contains(where: { s.contains($0) }) && s.count < 38 {
            return true
        }
        if (s.hasPrefix("こんにちは") || s.hasPrefix("こんばんは") || s.hasPrefix("おはようございます")) && s.count < 28 {
            return true
        }
        if s.hasSuffix("です") && s.count <= 16 && !s.contains("決定") && !s.contains("課題") && !s.contains("方針") {
            return true
        }
        return false
    }

    /// 話し言葉の1文から挨拶・冗長表現を削ぎ落とし、簡潔な要点（体言止め・要約調）に圧縮する
    public static func compressSentenceToKeyPoint(_ sentence: String) -> String {
        var s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }

        // 1. 冒頭に含まれがちな挨拶・フィラー前置きを除去
        let leadingNoisePrefixes = [
            "こんにちは。", "こんにちは、", "こんにちは",
            "それでは、", "それでは", "さて、", "えーと、", "あのー、",
            "ちなみに、", "まず、", "このチャンネルでは、", "このチャンネルでは",
            "今回の動画では、", "今回の動画では", "本日の議題として、", "本日は、"
        ]
        for prefix in leadingNoisePrefixes {
            if s.hasPrefix(prefix) && s.count > prefix.count + 4 {
                s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // 「〜へようこそ」「〜の〇〇です」が文頭に結合している場合は後ろの本題だけを取り出す
        if let welcomeRange = s.range(of: "ようこそ") {
            let after = String(s[welcomeRange.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "。、 "))
            if after.count >= 8 {
                s = after
            }
        }

        // 2. 文末の冗長な話し言葉表現を簡潔な要約調（体言止め等）に置換
        let suffixReplacements: [(target: String, replacement: String)] = [
            ("をお届けしています", "の情報を提供"),
            ("をお届けします", "の情報を提供"),
            ("について解説していきます", "の解説"),
            ("について解説します", "の解説"),
            ("についてお話しします", "についての議論"),
            ("について説明します", "の説明"),
            ("を確認します", "の確認"),
            ("かなと思います", ""),
            ("だと思います", ""),
            ("と考えています", ""),
            ("となっております", ""),
            ("になっています", ""),
            ("ということです", ""),
            ("ことができます", "が可能"),
            ("していきます", "を推進"),
            ("見ていきましょう", "の確認")
        ]
        for item in suffixReplacements {
            if s.hasSuffix(item.target) && s.count > item.target.count + 4 {
                s = String(s.dropLast(item.target.count)) + item.replacement
                break
            }
        }

        // 3. 「考えの方に」→「検討層向けに」等の自然な圧縮
        s = s.replacingOccurrences(of: "を考えの方に", with: "を検討する層へ")
            .replacingOccurrences(of: "をお考えの方に", with: "を検討する層へ")

        // 長すぎる場合は60文字でスマートに丸める
        if s.count > 62 {
            let idx = s.index(s.startIndex, offsetBy: 60)
            s = String(s[..<idx]) + "…"
        }
        return s
    }

    /// 発話群から主要キーワード（名詞句・専門用語）を抽出し、35文字以内の端的な「現在の論点・テーマ」見出しを生成する
    public static func buildConciseTopicHeadline(
        explicitTopics: [String],
        keyPoints: [String],
        segments: [TranscriptSegment]
    ) -> String {
        if let lastExplicit = explicitTopics.last, lastExplicit.count <= 42 {
            return lastExplicit
        }

        // 直近3セグメントから NLTagger とパターン抽出で重要キーワード（名詞・専門用語）を抽出
        let recentText = segments.suffix(3).map(\.correctedText).joined(separator: "。")
        let keywords = extractSalientTopicKeywords(from: recentText)

        // 直近の要点からタイムスタンプ `[00:00] ` を除いた本文を取得
        if let latestPoint = keyPoints.last {
            let cleanPoint: String
            if let bracketEnd = latestPoint.range(of: "] ") {
                cleanPoint = String(latestPoint[bracketEnd.upperBound...])
            } else {
                cleanPoint = latestPoint
            }
            if cleanPoint.count <= 36 {
                return cleanPoint
            }
            if !keywords.isEmpty {
                return "\(keywords.prefix(3).joined(separator: "・")) に関する議論"
            }
            let idx = cleanPoint.index(cleanPoint.startIndex, offsetBy: 34)
            return String(cleanPoint[..<idx]) + "…"
        }

        if !keywords.isEmpty {
            return "\(keywords.prefix(3).joined(separator: "・")) について"
        }

        return "導入・オープニング"
    }

    /// NaturalLanguage (NLTagger) を用いてテキストから重要キーワード・名詞を抽出する
    public static func extractSalientTopicKeywords(from text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let stopWords: Set<String> = [
            "こと", "もの", "ため", "よう", "ところ", "これ", "それ", "あれ", "ここ", "そこ",
            "わたし", "私", "僕", "今日", "本日", "今回", "チャンネル", "動画", "リンク", "概要欄",
            "皆さん", "みな", "方", "ようこそ", "挨拶", "話者", "確認", "実施", "対応"
        ]

        var results: [String] = []
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text

        var currentCompound = ""
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, tokenRange in
            let token = String(text[tokenRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if tag == .noun || tag == .otherWord {
                if !stopWords.contains(token) && token.count >= 2 {
                    if currentCompound.count + token.count <= 14 {
                        currentCompound += token
                    } else {
                        if currentCompound.count >= 2 && !results.contains(currentCompound) {
                            results.append(currentCompound)
                        }
                        currentCompound = token
                    }
                }
            } else {
                if currentCompound.count >= 2 && !stopWords.contains(currentCompound) && !results.contains(currentCompound) {
                    results.append(currentCompound)
                }
                currentCompound = ""
            }
            return true
        }
        if currentCompound.count >= 2 && !stopWords.contains(currentCompound) && !results.contains(currentCompound) {
            results.append(currentCompound)
        }

        return Array(results.prefix(5))
    }

    private func computeRelatedSuggestions(
        recentUtteranceText: String,
        fullTranscriptText: String,
        currentTranscriptId: UUID?,
        activeProjectId: UUID?
    ) -> [RelatedResourceSuggestion] {
        var suggestions: [RelatedResourceSuggestion] = []
        var seenSourceIds: Set<UUID> = []

        let vocabs = projectService.activeVocabularies(
            forProjectIds: activeProjectId.map { [$0] } ?? projectService.projects.map(\.id)
        )

        var activeKeywords: [String] = []
        for vocab in vocabs {
            if recentUtteranceText.localizedCaseInsensitiveContains(vocab.canonicalForm) ||
               fullTranscriptText.localizedCaseInsensitiveContains(vocab.canonicalForm) {
                activeKeywords.append(vocab.canonicalForm)
            }
        }

        let fallbackTopicWords = ["STT", "Qwen3-ASR", "WhisperKit", "Gemma 4", "ScreenCaptureKit", "SQLite", "FTS5", "仕様", "アーキテクチャ", "メモリ", "録音", "議事録", "AI", "ビジネス"]
        for word in fallbackTopicWords where (recentUtteranceText.localizedCaseInsensitiveContains(word) || fullTranscriptText.localizedCaseInsensitiveContains(word)) && !activeKeywords.contains(word) {
            activeKeywords.append(word)
        }

        let searchQuery = activeKeywords.isEmpty ? recentUtteranceText : activeKeywords.joined(separator: " ")
        let scope: SearchScopeMode = activeProjectId != nil ? .projectPriority : .global
        let rankedChunks = searchService.search(
            query: searchQuery,
            scopeMode: scope,
            targetProjectId: activeProjectId,
            limit: 12
        )

        for item in rankedChunks {
            switch item.chunk.sourceType {
            case .document:
                guard !seenSourceIds.contains(item.chunk.sourceId),
                      let doc = documentService.documents.first(where: { $0.id == item.chunk.sourceId }) else { continue }
                seenSourceIds.insert(doc.id)
                let matchedKWs = activeKeywords.filter { doc.extractedText.localizedCaseInsensitiveContains($0) || doc.fileName.localizedCaseInsensitiveContains($0) }
                let reason = matchedKWs.isEmpty
                    ? "現在の会話内容との意味的類似度 (\(Int(item.breakdown.totalScore * 100))%)"
                    : "会話中の『\(matchedKWs.prefix(3).joined(separator: "・"))』に関連する資料"
                suggestions.append(
                    RelatedResourceSuggestion(
                        kind: .document,
                        sourceId: doc.id,
                        title: doc.fileName,
                        subtitle: "\(doc.category.rawValue) ・ タグ: \(doc.tags.joined(separator: ", "))",
                        matchedKeywords: matchedKWs,
                        matchedReason: reason,
                        snippet: item.chunk.content,
                        fullPreviewText: doc.extractedText,
                        relevanceScore: item.breakdown.totalScore
                    )
                )

            case .meetingMinutes:
                guard !seenSourceIds.contains(item.chunk.sourceId),
                      let meeting = llmService.meetings.first(where: { $0.id == item.chunk.sourceId }),
                      meeting.transcriptId != currentTranscriptId else { continue }
                seenSourceIds.insert(meeting.id)
                let matchedKWs = activeKeywords.filter { meeting.markdownContent.localizedCaseInsensitiveContains($0) }
                let reason = matchedKWs.isEmpty
                    ? "過去の類似議題・決定事項 (\(Int(item.breakdown.totalScore * 100))%)"
                    : "『\(matchedKWs.prefix(3).joined(separator: "・"))』に関する過去の議事録"
                suggestions.append(
                    RelatedResourceSuggestion(
                        kind: .pastMeeting,
                        sourceId: meeting.id,
                        title: meeting.title,
                        subtitle: "決定事項 \(meeting.decisions.count)件 / TODO \(meeting.actionItems.count)件",
                        matchedKeywords: matchedKWs,
                        matchedReason: reason,
                        snippet: item.chunk.content,
                        fullPreviewText: meeting.markdownContent,
                        relevanceScore: item.breakdown.totalScore
                    )
                )

            case .transcriptSegment:
                break
            }
        }

        for doc in documentService.documents where !seenSourceIds.contains(doc.id) {
            let matchedKWs = activeKeywords.filter { doc.extractedText.localizedCaseInsensitiveContains($0) || doc.fileName.localizedCaseInsensitiveContains($0) }
            if !matchedKWs.isEmpty {
                seenSourceIds.insert(doc.id)
                suggestions.append(
                    RelatedResourceSuggestion(
                        kind: .document,
                        sourceId: doc.id,
                        title: doc.fileName,
                        subtitle: doc.category.rawValue,
                        matchedKeywords: matchedKWs,
                        matchedReason: "発話内の『\(matchedKWs.prefix(3).joined(separator: "・"))』が記載された資料",
                        snippet: doc.summary,
                        fullPreviewText: doc.extractedText,
                        relevanceScore: 0.72
                    )
                )
            }
        }

        for vocab in vocabs where activeKeywords.contains(vocab.canonicalForm) {
            guard !seenSourceIds.contains(vocab.id) else { continue }
            seenSourceIds.insert(vocab.id)
            let detail = """
            【用語】\(vocab.canonicalForm) \(vocab.reading.isEmpty ? "" : "(\(vocab.reading))")
            【区分】\(vocab.priorityScope.label)
            【解説】\(vocab.definition)
            【よくある誤認識】\(vocab.commonMisrecognitions.isEmpty ? "なし" : vocab.commonMisrecognitions.joined(separator: ", "))
            """
            suggestions.append(
                RelatedResourceSuggestion(
                    kind: .vocabulary,
                    sourceId: vocab.id,
                    title: "用語解説: \(vocab.canonicalForm)",
                    subtitle: vocab.reading.isEmpty ? vocab.priorityScope.label : "読み: \(vocab.reading)",
                    matchedKeywords: [vocab.canonicalForm],
                    matchedReason: "発話内で言及された専門用語",
                    snippet: vocab.definition,
                    fullPreviewText: detail,
                    relevanceScore: 0.65
                )
            )
        }

        return suggestions.sorted { $0.relevanceScore > $1.relevanceScore }
    }

    private func buildInitialProjectSuggestions(projectId: UUID?) -> [RelatedResourceSuggestion] {
        var list: [RelatedResourceSuggestion] = []
        for doc in documentService.documents.prefix(3) {
            list.append(
                RelatedResourceSuggestion(
                    kind: .document,
                    sourceId: doc.id,
                    title: doc.fileName,
                    subtitle: doc.category.rawValue,
                    matchedKeywords: doc.tags,
                    matchedReason: "プロジェクトの主要参照資料",
                    snippet: doc.summary,
                    fullPreviewText: doc.extractedText,
                    relevanceScore: 0.80
                )
            )
        }
        return list
    }
}
