import Foundation

public enum DocumentStorageMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case referencedInPlace = "referencedInPlace"
    case copiedToManagedStorage = "copiedToManagedStorage"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .referencedInPlace: "元の場所を参照（コピーしない）"
        case .copiedToManagedStorage: "アプリ管理領域へコピーして保持"
        }
    }
}

public enum DocumentFileType: String, Codable, CaseIterable, Sendable {
    case txt = "TXT"
    case markdown = "Markdown"
    case json = "JSON"
    case sourceCode = "SourceCode"
    case image = "Image"
    case pdf = "PDF"
    case officeDocument = "OfficeDocument"
    case other = "Other"

    /// テキスト系ファイルかどうか
    public var isTextFile: Bool {
        switch self {
        case .txt, .markdown, .json, .sourceCode:
            return true
        case .image, .pdf, .officeDocument, .other:
            return false
        }
    }

    /// 画像ファイル（Vision OCR対象）かどうか
    public var isImageFile: Bool {
        self == .image
    }

    /// 現在のフォルダ一括読み込み・自動再読み込みの対象形式かどうか
    /// （現フェーズではテキストファイルと画像ファイルのみを対象とし、PDF・Microsoft Office文書は今後の拡張対象とする）
    public var isSupportedInFolderBulkImport: Bool {
        isTextFile || isImageFile
    }

    public var displayName: String {
        switch self {
        case .txt: "テキスト (TXT/CSV/LOG)"
        case .markdown: "Markdown (MD)"
        case .json: "JSON"
        case .sourceCode: "ソースコード・設定"
        case .image: "画像 (Vision OCR)"
        case .pdf: "PDF (今後対応)"
        case .officeDocument: "Office文書 (今後対応)"
        case .other: "その他"
        }
    }
}

/// 監視・一括読み込み対象フォルダの永続化レコード
public struct WatchedFolderRecord: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var folderPath: String
    public var projectId: UUID?
    public var includeSubdirectories: Bool
    public var isEnabled: Bool
    public var importedDocumentCount: Int
    public var textDocumentCount: Int
    public var imageDocumentCount: Int
    public var skippedUnsupportedCount: Int
    public var lastScannedAt: Date?
    public var lastStatusSummary: String
    public var createdAt: Date

    public var lastSyncStatusMessage: String { lastStatusSummary }

    public init(
        id: UUID = UUID(),
        folderPath: String,
        projectId: UUID? = nil,
        includeSubdirectories: Bool = true,
        isEnabled: Bool = true,
        importedDocumentCount: Int = 0,
        textDocumentCount: Int = 0,
        imageDocumentCount: Int = 0,
        skippedUnsupportedCount: Int = 0,
        lastScannedAt: Date? = nil,
        lastStatusSummary: String = "待機中",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.folderPath = folderPath
        self.projectId = projectId
        self.includeSubdirectories = includeSubdirectories
        self.isEnabled = isEnabled
        self.importedDocumentCount = importedDocumentCount
        self.textDocumentCount = textDocumentCount
        self.imageDocumentCount = imageDocumentCount
        self.skippedUnsupportedCount = skippedUnsupportedCount
        self.lastScannedAt = lastScannedAt
        self.lastStatusSummary = lastStatusSummary
        self.createdAt = createdAt
    }
}

/// フォルダ指定一括読み込み・差分同期の実行結果サマリ
public struct FolderBulkImportSummary: Codable, Sendable, Equatable, Hashable {
    public var folderPath: String
    public var scannedFileCount: Int
    public var newlyImportedCount: Int
    public var textImportedCount: Int
    public var imageImportedCount: Int
    public var updatedReloadedCount: Int
    public var unchangedSkippedCount: Int
    public var unsupportedSkippedCount: Int
    public var inaccessibleMarkedCount: Int
    public var durationMs: Double

    public var unavailableRemovedCount: Int { inaccessibleMarkedCount }
    public var elapsedMs: Double { durationMs }
    public var statusSummaryText: String {
        "新規\(newlyImportedCount)件 (Text \(textImportedCount) / 画像OCR \(imageImportedCount)) / 更新\(updatedReloadedCount)件 / 未変更\(unchangedSkippedCount)件 (対象外スキップ\(unsupportedSkippedCount)件)"
    }

    public init(
        folderPath: String,
        scannedFileCount: Int = 0,
        newlyImportedCount: Int = 0,
        textImportedCount: Int = 0,
        imageImportedCount: Int = 0,
        updatedReloadedCount: Int = 0,
        unchangedSkippedCount: Int = 0,
        unsupportedSkippedCount: Int = 0,
        inaccessibleMarkedCount: Int = 0,
        durationMs: Double = 0
    ) {
        self.folderPath = folderPath
        self.scannedFileCount = scannedFileCount
        self.newlyImportedCount = newlyImportedCount
        self.textImportedCount = textImportedCount
        self.imageImportedCount = imageImportedCount
        self.updatedReloadedCount = updatedReloadedCount
        self.unchangedSkippedCount = unchangedSkippedCount
        self.unsupportedSkippedCount = unsupportedSkippedCount
        self.inaccessibleMarkedCount = inaccessibleMarkedCount
        self.durationMs = durationMs
    }
}

public enum DocumentCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case specification = "仕様書・設計書"
    case meetingMinutes = "議事録・会議メモ"
    case sourceCode = "ソースコード・実装"
    case researchNote = "技術調査・論文・ベンチマーク"
    case configuration = "設定・構成ファイル"
    case general = "一般文書"

    public var id: String { rawValue }
}

/// Entity #2: Document
public struct Document: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var fileName: String
    public var filePath: String
    public var originalPath: String
    public var storageMode: DocumentStorageMode
    public var fileType: DocumentFileType
    public var fileSizeBytes: Int64
    public var contentHash: String
    public var extractedText: String
    public var category: DocumentCategory
    public var tags: [String]
    public var summary: String
    public var relatedDocumentIds: [UUID]
    public var classificationStage: String
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        fileName: String,
        filePath: String,
        originalPath: String,
        storageMode: DocumentStorageMode = .referencedInPlace,
        fileType: DocumentFileType,
        fileSizeBytes: Int64 = 0,
        contentHash: String = "",
        extractedText: String = "",
        category: DocumentCategory = .general,
        tags: [String] = [],
        summary: String = "",
        relatedDocumentIds: [UUID] = [],
        classificationStage: String = "未分類",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.fileName = fileName
        self.filePath = filePath
        self.originalPath = originalPath
        self.storageMode = storageMode
        self.fileType = fileType
        self.fileSizeBytes = fileSizeBytes
        self.contentHash = contentHash
        self.extractedText = extractedText
        self.category = category
        self.tags = tags
        self.summary = summary
        self.relatedDocumentIds = relatedDocumentIds
        self.classificationStage = classificationStage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Entity #3: ProjectDocument
public struct ProjectDocument: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var projectId: UUID
    public var documentId: UUID
    public var relevanceScore: Double
    public var isSuggestedByAI: Bool
    public var isApproved: Bool
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        projectId: UUID,
        documentId: UUID,
        relevanceScore: Double = 1.0,
        isSuggestedByAI: Bool = false,
        isApproved: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.projectId = projectId
        self.documentId = documentId
        self.relevanceScore = relevanceScore
        self.isSuggestedByAI = isSuggestedByAI
        self.isApproved = isApproved
        self.createdAt = createdAt
    }
}

public enum KnowledgeSourceType: String, Codable, CaseIterable, Sendable {
    case document = "ファイル"
    case transcriptSegment = "文字起こし"
    case meetingMinutes = "議事録"
}

/// Entity #10: KnowledgeChunk
public struct KnowledgeChunk: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var sourceType: KnowledgeSourceType
    public var sourceId: UUID
    public var projectIds: [UUID]
    public var title: String
    public var content: String
    public var chunkIndex: Int
    public var locationHint: String
    public var isDecisionOrImportant: Bool
    public var sourceUpdatedAt: Date
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        sourceType: KnowledgeSourceType,
        sourceId: UUID,
        projectIds: [UUID] = [],
        title: String,
        content: String,
        chunkIndex: Int = 0,
        locationHint: String = "",
        isDecisionOrImportant: Bool = false,
        sourceUpdatedAt: Date = Date(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sourceType = sourceType
        self.sourceId = sourceId
        self.projectIds = projectIds
        self.title = title
        self.content = content
        self.chunkIndex = chunkIndex
        self.locationHint = locationHint
        self.isDecisionOrImportant = isDecisionOrImportant
        self.sourceUpdatedAt = sourceUpdatedAt
        self.createdAt = createdAt
    }
}

/// Entity #11: EmbeddingRecord
public struct EmbeddingRecord: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var chunkId: UUID
    public var modelId: String
    public var dimensions: Int
    public var vector: [Float]
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        chunkId: UUID,
        modelId: String,
        dimensions: Int,
        vector: [Float],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.chunkId = chunkId
        self.modelId = modelId
        self.dimensions = dimensions
        self.vector = vector
        self.createdAt = createdAt
    }
}

public enum FileOperationType: String, Codable, CaseIterable, Sendable {
    case rename = "ファイル名変更"
    case moveFolder = "フォルダ移動"
    case updateTags = "タグ付け"
    case associateProject = "プロジェクト関連付け"
    case combinedOrganize = "AI整理提案（複合）"
}

public enum FileOperationStatus: String, Codable, CaseIterable, Sendable {
    case pendingApproval = "承認待ち"
    case approvedAndApplied = "適用済み"
    case rejected = "却下"
    case undone = "取り消し済み（ロールバック）"
}

/// Entity #15: FileOperationHistory
public struct FileOperationHistory: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var documentId: UUID
    public var operationType: FileOperationType
    public var previousFileName: String
    public var proposedFileName: String
    public var previousFilePath: String
    public var proposedFilePath: String
    public var previousCategory: DocumentCategory
    public var proposedCategory: DocumentCategory
    public var previousTags: [String]
    public var proposedTags: [String]
    public var previousProjectIds: [UUID]
    public var proposedProjectIds: [UUID]
    public var reason: String
    public var modelId: String
    public var status: FileOperationStatus
    public var createdAt: Date
    public var appliedAt: Date?
    public var undoneAt: Date?

    public init(
        id: UUID = UUID(),
        documentId: UUID,
        operationType: FileOperationType,
        previousFileName: String,
        proposedFileName: String,
        previousFilePath: String,
        proposedFilePath: String,
        previousCategory: DocumentCategory,
        proposedCategory: DocumentCategory,
        previousTags: [String],
        proposedTags: [String],
        previousProjectIds: [UUID],
        proposedProjectIds: [UUID],
        reason: String,
        modelId: String,
        status: FileOperationStatus = .pendingApproval,
        createdAt: Date = Date(),
        appliedAt: Date? = nil,
        undoneAt: Date? = nil
    ) {
        self.id = id
        self.documentId = documentId
        self.operationType = operationType
        self.previousFileName = previousFileName
        self.proposedFileName = proposedFileName
        self.previousFilePath = previousFilePath
        self.proposedFilePath = proposedFilePath
        self.previousCategory = previousCategory
        self.proposedCategory = proposedCategory
        self.previousTags = previousTags
        self.proposedTags = proposedTags
        self.previousProjectIds = previousProjectIds
        self.proposedProjectIds = proposedProjectIds
        self.reason = reason
        self.modelId = modelId
        self.status = status
        self.createdAt = createdAt
        self.appliedAt = appliedAt
        self.undoneAt = undoneAt
    }
}

public enum SearchScopeMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case global = "global"
    case projectPriority = "projectPriority"
    case projectExclusive = "projectExclusive"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .global: "全体検索"
        case .projectPriority: "プロジェクト優先検索"
        case .projectExclusive: "プロジェクト限定検索"
        }
    }

    public var description: String {
        switch self {
        case .global: "アクセスが許可されている全データを検索"
        case .projectPriority: "指定プロジェクトを優先しつつ、他プロジェクト・未所属データも検索"
        case .projectExclusive: "指定したプロジェクトに所属するデータのみを厳密に検索"
        }
    }
}

public struct SearchScoreBreakdown: Codable, Sendable, Equatable, Hashable {
    public var semanticSimilarity: Double
    public var keywordMatchScore: Double
    public var filenameMatchScore: Double
    public var projectAlignmentScore: Double
    public var recencyScore: Double
    public var importanceScore: Double
    public var totalScore: Double

    public init(
        semanticSimilarity: Double,
        keywordMatchScore: Double,
        filenameMatchScore: Double,
        projectAlignmentScore: Double,
        recencyScore: Double,
        importanceScore: Double,
        totalScore: Double
    ) {
        self.semanticSimilarity = semanticSimilarity
        self.keywordMatchScore = keywordMatchScore
        self.filenameMatchScore = filenameMatchScore
        self.projectAlignmentScore = projectAlignmentScore
        self.recencyScore = recencyScore
        self.importanceScore = importanceScore
        self.totalScore = totalScore
    }
}

public struct SearchResultItem: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID { chunk.id }
    public var chunk: KnowledgeChunk
    public var breakdown: SearchScoreBreakdown

    public init(chunk: KnowledgeChunk, breakdown: SearchScoreBreakdown) {
        self.chunk = chunk
        self.breakdown = breakdown
    }
}

public struct ChatCitation: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var chunkId: UUID
    public var sourceType: KnowledgeSourceType
    public var sourceId: UUID
    public var title: String
    public var snippet: String
    public var locationHint: String
    public var score: Double

    public init(
        id: UUID = UUID(),
        chunkId: UUID,
        sourceType: KnowledgeSourceType,
        sourceId: UUID,
        title: String,
        snippet: String,
        locationHint: String,
        score: Double
    ) {
        self.id = id
        self.chunkId = chunkId
        self.sourceType = sourceType
        self.sourceId = sourceId
        self.title = title
        self.snippet = snippet
        self.locationHint = locationHint
        self.score = score
    }
}

public struct ChatMessage: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: UUID
    public var isUser: Bool
    public var content: String
    public var citations: [ChatCitation]
    public var hasSufficientEvidence: Bool
    public var searchScope: SearchScopeMode
    public var projectId: UUID?
    public var modelId: String
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        isUser: Bool,
        content: String,
        citations: [ChatCitation] = [],
        hasSufficientEvidence: Bool = true,
        searchScope: SearchScopeMode = .global,
        projectId: UUID? = nil,
        modelId: String = "",
        createdAt: Date = Date()
    ) {
        self.id = id
        self.isUser = isUser
        self.content = content
        self.citations = citations
        self.hasSufficientEvidence = hasSufficientEvidence
        self.searchScope = searchScope
        self.projectId = projectId
        self.modelId = modelId
        self.createdAt = createdAt
    }
}
