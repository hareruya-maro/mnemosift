import Foundation
import Observation

public struct LiveDiscussionDigest: Codable, Sendable, Equatable {
    public var currentTopic: String
    public var keyPoints: [String]
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var unresolvedQuestions: [String]
    public var utteranceCount: Int
    public var updatedAt: Date

    public init(
        currentTopic: String = "会議待機中（発話が始まると自動で論点を要約します）",
        keyPoints: [String] = [],
        decisions: [String] = [],
        actionItems: [ActionItem] = [],
        unresolvedQuestions: [String] = [],
        utteranceCount: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.currentTopic = currentTopic
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actionItems = actionItems
        self.unresolvedQuestions = unresolvedQuestions
        self.utteranceCount = utteranceCount
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
/// - リアルタイム文字起こしの進行に合わせて「議論のライブ要約」と「関連資料・過去議事録・専門用語の自動提案」を即時更新する
@Observable
@MainActor
public final class MeetingPartnerService {
    private let searchService: SearchService
    private let documentService: DocumentService
    private let llmService: LLMService
    private let projectService: ProjectService

    public private(set) var liveDigest: LiveDiscussionDigest = LiveDiscussionDigest()
    public private(set) var relatedSuggestions: [RelatedResourceSuggestion] = []
    public var previewingSuggestion: RelatedResourceSuggestion?

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
        activeProjectId: UUID?
    ) {
        guard !segments.isEmpty else {
            self.liveDigest = LiveDiscussionDigest()
            self.relatedSuggestions = buildInitialProjectSuggestions(projectId: activeProjectId)
            return
        }

        // 1. リアルタイム議論要約の構築
        var topics: [String] = []
        var keyPoints: [String] = []
        var decisions: [String] = []
        var actionItems: [ActionItem] = []
        var unresolved: [String] = []

        for seg in segments {
            let text = seg.correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let timeStr = LocalLLMAdapter.formatTimestamp(seg.startTimeSeconds)

            if text.contains("議題") || text.contains("テーマ") || text.contains("確認します") || text.contains("について") {
                topics.append(text)
            }
            if text.contains("決定") || text.contains("採用") || text.contains("方針") || text.contains("合意") || text.contains("こととします") {
                decisions.append("[\(timeStr)] \(text)")
            } else if text.contains("TODO") || text.contains("アクション") || text.contains("までに") || text.contains("実施します") || text.contains("対応します") {
                let assignee = LocalLLMAdapter.extractExplicitAssignee(from: text)
                let due = LocalLLMAdapter.extractExplicitDueDate(from: text)
                actionItems.append(
                    ActionItem(
                        title: text,
                        assignee: assignee,
                        dueDateText: due,
                        isCompleted: false,
                        sourceSegmentId: seg.id
                    )
                )
            } else if text.contains("課題") || text.contains("未解決") || text.contains("検討中") || text.contains("保留") {
                unresolved.append("[\(timeStr)] \(text)")
            } else {
                keyPoints.append("[\(timeStr)] \(seg.speakerLabel): \(text)")
            }
        }

        let latestTopic = topics.last ?? segments.last?.correctedText ?? "議論進行中"
        if keyPoints.isEmpty {
            keyPoints = segments.suffix(3).map { "[\(LocalLLMAdapter.formatTimestamp($0.startTimeSeconds))] \($0.speakerLabel): \($0.correctedText)" }
        }

        self.liveDigest = LiveDiscussionDigest(
            currentTopic: latestTopic,
            keyPoints: Array(keyPoints.suffix(5)),
            decisions: decisions,
            actionItems: actionItems,
            unresolvedQuestions: unresolved,
            utteranceCount: segments.count,
            updatedAt: Date()
        )

        // 2. 直近の発話内容（最新3発話を重点、全体も補助）から関連資料・過去議事録・用語を自動提案
        let recentText = segments.suffix(3).map(\.correctedText).joined(separator: " ")
        let allText = segments.map(\.correctedText).joined(separator: " ")
        self.relatedSuggestions = computeRelatedSuggestions(
            recentUtteranceText: recentText,
            fullTranscriptText: allText,
            currentTranscriptId: transcript?.id,
            activeProjectId: activeProjectId ?? transcript?.projectIds.first
        )
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

        // 発話中に登場した重要キーワード・専門用語を抽出
        var activeKeywords: [String] = []
        for vocab in vocabs {
            if recentUtteranceText.localizedCaseInsensitiveContains(vocab.canonicalForm) ||
               fullTranscriptText.localizedCaseInsensitiveContains(vocab.canonicalForm) {
                activeKeywords.append(vocab.canonicalForm)
            }
        }

        let fallbackTopicWords = ["STT", "Qwen3-ASR", "WhisperKit", "Gemma 4", "ScreenCaptureKit", "SQLite", "FTS5", "仕様", "アーキテクチャ", "メモリ", "録音", "議事録"]
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

        // (A) 検索ヒットしたローカル資料 (Document) と 過去議事録 (Meeting) を提案リストへ変換
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

        // もし登録済みドキュメントがあるのにまだ含まれていない場合は、キーワード一致で補完
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

        // (B) 会話中に登場した専門用語のクイック解説カードも提案
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
