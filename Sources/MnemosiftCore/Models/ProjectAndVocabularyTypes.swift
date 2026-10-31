import Foundation

public struct ClassificationRule: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var filenameKeyword: String
    public var contentKeyword: String
    public var targetCategory: DocumentCategory
    public var targetTags: [String]
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        filenameKeyword: String = "",
        contentKeyword: String = "",
        targetCategory: DocumentCategory = .general,
        targetTags: [String] = [],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.filenameKeyword = filenameKeyword
        self.contentKeyword = contentKeyword
        self.targetCategory = targetCategory
        self.targetTags = targetTags
        self.isEnabled = isEnabled
    }
}

/// Entity #1: Project
public struct Project: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var description: String
    public var relatedFolderPaths: [String]
    public var defaultTemplateId: String
    public var classificationRules: [ClassificationRule]
    public var customAISettings: AISettings?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        description: String = "",
        relatedFolderPaths: [String] = [],
        defaultTemplateId: String = "template-standard",
        classificationRules: [ClassificationRule] = [],
        customAISettings: AISettings? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.relatedFolderPaths = relatedFolderPaths
        self.defaultTemplateId = defaultTemplateId
        self.classificationRules = classificationRules
        self.customAISettings = customAISettings
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum VocabularySource: String, Codable, CaseIterable, Sendable {
    case manual = "手動登録"
    case extractedFromDocument = "関連文書からAI抽出"
    case extractedFromMeeting = "過去議事録からAI抽出"
    case generatedFromCorrectionHistory = "補正履歴から候補生成"
}

public enum VocabularyApprovalStatus: String, Codable, CaseIterable, Sendable {
    case approved = "承認済み"
    case candidate = "候補（承認待ち）"
    case rejected = "却下"
}

public enum VocabularyPriorityScope: Int, Codable, CaseIterable, Sendable, Comparable {
    case runtimeSpecified = 1
    case projectDictionary = 2
    case commonDictionary = 3

    public static func < (lhs: VocabularyPriorityScope, rhs: VocabularyPriorityScope) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .runtimeSpecified: "実行時指定（優先度1）"
        case .projectDictionary: "プロジェクト辞書（優先度2）"
        case .commonDictionary: "共通辞書（優先度3）"
        }
    }
}

/// Entity #9: Vocabulary
public struct Vocabulary: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var projectId: UUID?
    public var canonicalForm: String
    public var reading: String
    public var aliases: [String]
    public var commonMisrecognitions: [String]
    public var definition: String
    public var usageFrequency: Int
    public var source: VocabularySource
    public var approvalStatus: VocabularyApprovalStatus
    public var priorityScope: VocabularyPriorityScope
    public var domainTags: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectId: UUID? = nil,
        canonicalForm: String,
        reading: String = "",
        aliases: [String] = [],
        commonMisrecognitions: [String] = [],
        definition: String = "",
        usageFrequency: Int = 0,
        source: VocabularySource = .manual,
        approvalStatus: VocabularyApprovalStatus = .approved,
        priorityScope: VocabularyPriorityScope? = nil,
        domainTags: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectId = projectId
        self.canonicalForm = canonicalForm
        self.reading = reading
        self.aliases = aliases
        self.commonMisrecognitions = commonMisrecognitions
        self.definition = definition
        self.usageFrequency = usageFrequency
        self.source = source
        self.approvalStatus = approvalStatus
        self.priorityScope = priorityScope ?? (projectId != nil ? .projectDictionary : .commonDictionary)
        self.domainTags = domainTags
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
