import Foundation

public enum MeetingTemplateType: String, Codable, CaseIterable, Sendable, Identifiable {
    case standard = "standard"
    case technical = "technical"
    case summaryOnly = "summaryOnly"
    case decisionsAndTodos = "decisionsAndTodos"
    case custom = "custom"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .standard: "標準議事録"
        case .technical: "技術会議"
        case .summaryOnly: "要点のみ"
        case .decisionsAndTodos: "決定事項・TODO中心"
        case .custom: "カスタムテンプレート"
        }
    }
}

public struct MeetingTemplate: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var type: MeetingTemplateType
    public var description: String
    public var instructions: String
    public var sections: [String]
    public var isBuiltIn: Bool

    public init(
        id: String,
        name: String,
        type: MeetingTemplateType,
        description: String,
        instructions: String,
        sections: [String],
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.description = description
        self.instructions = instructions
        self.sections = sections
        self.isBuiltIn = isBuiltIn
    }

    public static let builtInTemplates: [MeetingTemplate] = [
        MeetingTemplate(
            id: "template-standard",
            name: "標準議事録",
            type: .standard,
            description: "会議概要・議題・議論内容・決定事項・TODO・未解決事項を網羅した標準形式",
            instructions: "発言の意味を変えず、担当者や期限が明確でない場合は『未定（発言内で未確定）』と記載し、推測で確定しないこと。",
            sections: ["会議の概要", "議題", "議論内容", "決定事項", "TODO・アクションアイテム", "未解決事項"],
            isBuiltIn: true
        ),
        MeetingTemplate(
            id: "template-technical",
            name: "技術会議",
            type: .technical,
            description: "アーキテクチャ選定・技術的課題・ベンチマーク数値・決定事項を重視する形式",
            instructions: "技術用語はプロジェクト辞書に準拠し、性能指標やトレードオフ、決定事項と残課題を明確に整理すること。",
            sections: ["会議の概要", "技術アジェンダ", "アーキテクチャ・技術議論", "技術的決定事項", "TODO・検証タスク", "未解決の技術課題"],
            isBuiltIn: true
        ),
        MeetingTemplate(
            id: "template-summary",
            name: "要点のみ",
            type: .summaryOnly,
            description: "短時間で全体を把握できるエグゼクティブサマリーと決定事項のみの簡潔な形式",
            instructions: "3〜5項目の要点と重要決定事項のみを簡潔にまとめること。",
            sections: ["会議の概要", "主要ポイント", "決定事項"],
            isBuiltIn: true
        ),
        MeetingTemplate(
            id: "template-decisions-todos",
            name: "決定事項・TODO中心",
            type: .decisionsAndTodos,
            description: "決定事項とネクストアクション（担当者・期限）の追跡に特化した形式",
            instructions: "決定された事項とアクションアイテムを最優先で抽出し、担当者・期限が不明な場合は推測せず未確定と明記すること。",
            sections: ["決定事項", "TODO・アクションアイテム", "未解決・次回持ち越し事項"],
            isBuiltIn: true
        )
    ]
}

public enum MeetingSectionKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case overview = "会議の概要"
    case agenda = "議題"
    case discussion = "議論内容"
    case decisions = "決定事項"
    case actionItems = "TODO・アクションアイテム"
    case unresolved = "未解決事項"

    public var id: String { rawValue }
}

public struct ActionItem: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var title: String
    /// 明確でない場合は nil（「担当者未定」として扱い推測しない）
    public var assignee: String?
    /// 明確でない場合は nil（「期限未定」として扱い推測しない）
    public var dueDateText: String?
    public var isCompleted: Bool
    public var sourceSegmentId: UUID?

    public init(
        id: UUID = UUID(),
        title: String,
        assignee: String? = nil,
        dueDateText: String? = nil,
        isCompleted: Bool = false,
        sourceSegmentId: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.assignee = assignee
        self.dueDateText = dueDateText
        self.isCompleted = isCompleted
        self.sourceSegmentId = sourceSegmentId
    }
}

/// Entity #8: Meeting
public struct Meeting: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var title: String
    public var recordingId: UUID?
    public var transcriptId: UUID?
    public var projectIds: [UUID]
    public var templateId: String
    public var llmModelId: String
    public var overview: String
    public var agendaItems: [String]
    public var discussionNotes: [String]
    public var decisions: [String]
    public var actionItems: [ActionItem]
    public var unresolvedIssues: [String]
    public var markdownContent: String
    public var contextNotes: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        recordingId: UUID? = nil,
        transcriptId: UUID? = nil,
        projectIds: [UUID] = [],
        templateId: String = "template-standard",
        llmModelId: String = "llm-gemma-4",
        overview: String = "",
        agendaItems: [String] = [],
        discussionNotes: [String] = [],
        decisions: [String] = [],
        actionItems: [ActionItem] = [],
        unresolvedIssues: [String] = [],
        markdownContent: String = "",
        contextNotes: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.recordingId = recordingId
        self.transcriptId = transcriptId
        self.projectIds = projectIds
        self.templateId = templateId
        self.llmModelId = llmModelId
        self.overview = overview
        self.agendaItems = agendaItems
        self.discussionNotes = discussionNotes
        self.decisions = decisions
        self.actionItems = actionItems
        self.unresolvedIssues = unresolvedIssues
        self.markdownContent = markdownContent
        self.contextNotes = contextNotes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
