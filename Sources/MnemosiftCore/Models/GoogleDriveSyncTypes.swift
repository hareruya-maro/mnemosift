import Foundation

// MARK: - Google Driveフォルダ自動同期機能 実装仕様書 v1.0 データモデル定義 (§2〜§12)

/// §2.2 Google OAuth 2.0 必須スコープと定数
public enum GoogleDriveConstants {
    public static let readOnlyScope = "https://www.googleapis.com/auth/drive.readonly"
    public static let googleDocMimeType = "application/vnd.google-apps.document"
    public static let googleFolderMimeType = "application/vnd.google-apps.folder"
    public static let googleShortcutMimeType = "application/vnd.google-apps.shortcut"
    public static let googleSpreadsheetMimeType = "application/vnd.google-apps.spreadsheet"
    public static let googlePresentationMimeType = "application/vnd.google-apps.presentation"
    public static let markdownExportMimeType = "text/markdown"
}

/// §3.1 フォルダの保管先ドライブ種別（マイドライブ / 共有フォルダ / 共有ドライブ）
public enum GoogleDriveLocationType: String, Codable, CaseIterable, Sendable, Identifiable {
    case myDrive = "my_drive"
    case sharedFolder = "shared_folder"
    case sharedDrive = "shared_drive"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .myDrive: "マイドライブ"
        case .sharedFolder: "共有フォルダ"
        case .sharedDrive: "共有ドライブ"
        }
    }
}

/// §2.4, §6.2, §11.1 Googleアカウント認証状態
public enum GoogleAccountStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case connected = "connected"
    case authRequired = "auth_required"
    case error = "error"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .connected: "連携中"
        case .authRequired: "再認証が必要"
        case .error: "認証エラー"
        }
    }
}

/// §8.1 同期フォルダごとのステータス
public enum GoogleSyncFolderStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case idle = "idle"
    case syncing = "syncing"
    case authRequired = "auth_required"
    case error = "error"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .idle: "待機中"
        case .syncing: "同期中"
        case .authRequired: "要再認証"
        case .error: "エラー"
        }
    }
}

/// §8.1 全体同期ステート
public enum GoogleDriveSyncState: Codable, Sendable, Equatable {
    case idle
    case syncing
    case paused
    case offline
    case authRequired(String)
    case error(String)

    public var displayName: String {
        switch self {
        case .idle: "待機中"
        case .syncing: "同期中..."
        case .paused: "一時停止中"
        case .offline: "オフライン"
        case .authRequired: "再認証が必要です"
        case .error(let msg): "エラー: \(msg)"
        }
    }
}

/// §6.5 外部文書同期ステータス
public enum ExternalDocumentSyncStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    case synced = "synced"
    case pending = "pending"
    case error = "error"

    public var id: String { rawValue }
}

/// §6.8 同期ジョブ変更種別
public enum GoogleSyncJobChangeType: String, Codable, CaseIterable, Sendable {
    case upsert = "upsert"
    case remove = "remove"
    case folderChange = "folder_change"
}

/// §6.8 同期ジョブ実行ステータス
public enum GoogleSyncJobStatus: String, Codable, CaseIterable, Sendable {
    case pending = "pending"
    case processing = "processing"
    case completed = "completed"
    case failed = "failed"
}

// MARK: - §6 SQLite テーブル対応モデル

/// §6.2 `google_accounts`
public struct GoogleAccountRecord: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var email: String
    public var displayName: String
    public var status: GoogleAccountStatus
    public var connectedAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        email: String,
        displayName: String = "",
        status: GoogleAccountStatus = .connected,
        connectedAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.email = email
        self.displayName = displayName
        self.status = status
        self.connectedAt = connectedAt
        self.updatedAt = updatedAt
    }
}

/// §6.3 `google_sync_folders`
public struct GoogleSyncFolderRecord: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var accountId: String
    public var folderId: String
    public var folderName: String
    public var folderPath: String
    public var driveType: GoogleDriveLocationType
    public var driveId: String?
    public var includeSubfolders: Bool
    public var syncEnabled: Bool
    public var syncStatus: GoogleSyncFolderStatus
    public var lastSyncedAt: Date?
    public var lastFullScanAt: Date?
    public var lastErrorMessage: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        accountId: String,
        folderId: String,
        folderName: String,
        folderPath: String = "",
        driveType: GoogleDriveLocationType = .myDrive,
        driveId: String? = nil,
        includeSubfolders: Bool = true,
        syncEnabled: Bool = true,
        syncStatus: GoogleSyncFolderStatus = .idle,
        lastSyncedAt: Date? = nil,
        lastFullScanAt: Date? = nil,
        lastErrorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.accountId = accountId
        self.folderId = folderId
        self.folderName = folderName
        self.folderPath = folderPath
        self.driveType = driveType
        self.driveId = driveId
        self.includeSubfolders = includeSubfolders
        self.syncEnabled = syncEnabled
        self.syncStatus = syncStatus
        self.lastSyncedAt = lastSyncedAt
        self.lastFullScanAt = lastFullScanAt
        self.lastErrorMessage = lastErrorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// §6.4 `google_folder_tree`
public struct GoogleFolderTreeNodeRecord: Codable, Sendable, Equatable, Hashable {
    public var accountId: String
    public var folderId: String
    public var parentFolderId: String?
    public var rootSyncFolderId: String
    public var folderName: String
    public var trashed: Bool
    public var updatedAt: Date

    public init(
        accountId: String,
        folderId: String,
        parentFolderId: String?,
        rootSyncFolderId: String,
        folderName: String,
        trashed: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.accountId = accountId
        self.folderId = folderId
        self.parentFolderId = parentFolderId
        self.rootSyncFolderId = rootSyncFolderId
        self.folderName = folderName
        self.trashed = trashed
        self.updatedAt = updatedAt
    }
}

/// §6.5 `external_documents`
public struct ExternalDocumentRecord: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var documentId: String
    public var provider: String
    public var accountId: String
    public var externalFileId: String
    public var parentFolderId: String?
    public var mimeType: String
    public var webViewLink: String
    public var remoteModifiedTime: String
    public var remoteVersion: String?
    public var contentHash: String
    public var syncStatus: ExternalDocumentSyncStatus
    public var lastSyncedAt: Date?
    public var lastErrorMessage: String?

    public init(
        id: String,
        documentId: String,
        provider: String = "google_drive",
        accountId: String,
        externalFileId: String,
        parentFolderId: String?,
        mimeType: String,
        webViewLink: String,
        remoteModifiedTime: String,
        remoteVersion: String?,
        contentHash: String,
        syncStatus: ExternalDocumentSyncStatus = .synced,
        lastSyncedAt: Date? = nil,
        lastErrorMessage: String? = nil
    ) {
        self.id = id
        self.documentId = documentId
        self.provider = provider
        self.accountId = accountId
        self.externalFileId = externalFileId
        self.parentFolderId = parentFolderId
        self.mimeType = mimeType
        self.webViewLink = webViewLink
        self.remoteModifiedTime = remoteModifiedTime
        self.remoteVersion = remoteVersion
        self.contentHash = contentHash
        self.syncStatus = syncStatus
        self.lastSyncedAt = lastSyncedAt
        self.lastErrorMessage = lastErrorMessage
    }
}

/// §6.6 `google_document_memberships`
public struct GoogleDocumentMembershipRecord: Codable, Sendable, Equatable, Hashable {
    public var accountId: String
    public var externalFileId: String
    public var syncFolderId: String
    public var folderId: String
    public var isActive: Bool
    public var updatedAt: Date

    public init(
        accountId: String,
        externalFileId: String,
        syncFolderId: String,
        folderId: String,
        isActive: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.accountId = accountId
        self.externalFileId = externalFileId
        self.syncFolderId = syncFolderId
        self.folderId = folderId
        self.isActive = isActive
        self.updatedAt = updatedAt
    }
}

/// §6.7 `google_sync_cursors`
public struct GoogleSyncCursorRecord: Codable, Sendable, Equatable, Hashable {
    public var accountId: String
    public var scopeKey: String
    public var pageToken: String
    public var updatedAt: Date

    public init(accountId: String, scopeKey: String = "default", pageToken: String, updatedAt: Date = Date()) {
        self.accountId = accountId
        self.scopeKey = scopeKey
        self.pageToken = pageToken
        self.updatedAt = updatedAt
    }
}

/// §6.8 `google_sync_jobs`
public struct GoogleSyncJobRecord: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var accountId: String
    public var externalFileId: String
    public var changeType: GoogleSyncJobChangeType
    public var payloadJSON: String
    public var status: GoogleSyncJobStatus
    public var retryCount: Int
    public var lastErrorMessage: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        accountId: String,
        externalFileId: String,
        changeType: GoogleSyncJobChangeType,
        payloadJSON: String,
        status: GoogleSyncJobStatus = .pending,
        retryCount: Int = 0,
        lastErrorMessage: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.accountId = accountId
        self.externalFileId = externalFileId
        self.changeType = changeType
        self.payloadJSON = payloadJSON
        self.status = status
        self.retryCount = retryCount
        self.lastErrorMessage = lastErrorMessage
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - §7.1 共通インポートインターフェース (`ImportableDocument`)

public struct ImportableDocument: Codable, Sendable, Equatable, Hashable {
    public var externalId: String?
    public var sourceType: IndexedDocumentSourceType
    public var title: String
    public var content: String
    public var sourceURI: String?
    public var createdAt: Date?
    public var updatedAt: Date?
    public var metadata: [String: String]

    public init(
        externalId: String? = nil,
        sourceType: IndexedDocumentSourceType = .googleDrive,
        title: String,
        content: String,
        sourceURI: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        metadata: [String: String] = [:]
    ) {
        self.externalId = externalId
        self.sourceType = sourceType
        self.title = title
        self.content = content
        self.sourceURI = sourceURI
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.metadata = metadata
    }
}

// MARK: - API レスポンス・データモデル

public struct GoogleDriveFileItem: Codable, Sendable, Identifiable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var mimeType: String
    public var parents: [String]
    public var modifiedTime: String
    public var webViewLink: String
    public var trashed: Bool
    public var driveId: String?
    public var version: String?
    public var createdTime: String?
    public var locationType: GoogleDriveLocationType

    public var isFolder: Bool {
        mimeType == GoogleDriveConstants.googleFolderMimeType
    }

    public var isGoogleDocument: Bool {
        mimeType == GoogleDriveConstants.googleDocMimeType
    }

    public var isShortcut: Bool {
        mimeType == GoogleDriveConstants.googleShortcutMimeType
    }

    public init(
        id: String,
        name: String,
        mimeType: String,
        parents: [String] = [],
        modifiedTime: String = "",
        webViewLink: String = "",
        trashed: Bool = false,
        driveId: String? = nil,
        version: String? = nil,
        createdTime: String? = nil,
        locationType: GoogleDriveLocationType = .myDrive
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.parents = parents
        self.modifiedTime = modifiedTime
        self.webViewLink = webViewLink.isEmpty ? "https://docs.google.com/document/d/\(id)/edit" : webViewLink
        self.trashed = trashed
        self.driveId = driveId
        self.version = version
        self.createdTime = createdTime
        self.locationType = locationType
    }

    public init(
        id: String,
        name: String,
        mimeType: String,
        parents: [String] = [],
        modifiedTime: Date,
        webViewLink: String = "",
        trashed: Bool = false,
        driveId: String? = nil,
        version: String? = nil,
        createdTime: String? = nil,
        locationType: GoogleDriveLocationType = .myDrive
    ) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.init(
            id: id,
            name: name,
            mimeType: mimeType,
            parents: parents,
            modifiedTime: formatter.string(from: modifiedTime),
            webViewLink: webViewLink,
            trashed: trashed,
            driveId: driveId,
            version: version,
            createdTime: createdTime,
            locationType: locationType
        )
    }
}

public struct GoogleDriveFileListPage: Codable, Sendable, Equatable {
    public var files: [GoogleDriveFileItem]
    public var nextPageToken: String?

    public init(files: [GoogleDriveFileItem], nextPageToken: String? = nil) {
        self.files = files
        self.nextPageToken = nextPageToken
    }
}

public struct GoogleDriveChangeItem: Codable, Sendable, Equatable, Hashable {
    public var fileId: String
    public var removed: Bool
    public var file: GoogleDriveFileItem?
    public var time: String
    public var driveId: String?

    public init(
        fileId: String,
        removed: Bool = false,
        file: GoogleDriveFileItem? = nil,
        time: String = "",
        driveId: String? = nil
    ) {
        self.fileId = fileId
        self.removed = removed
        self.file = file
        self.time = time
        self.driveId = driveId
    }

    public init(
        fileId: String,
        removed: Bool = false,
        file: GoogleDriveFileItem? = nil,
        time: Date,
        driveId: String? = nil
    ) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.init(
            fileId: fileId,
            removed: removed,
            file: file,
            time: formatter.string(from: time),
            driveId: driveId
        )
    }
}

public struct GoogleDriveChangeListPage: Codable, Sendable, Equatable {
    public var changes: [GoogleDriveChangeItem]
    public var nextPageToken: String?
    public var newStartPageToken: String?

    public init(
        changes: [GoogleDriveChangeItem],
        nextPageToken: String? = nil,
        newStartPageToken: String? = nil
    ) {
        self.changes = changes
        self.nextPageToken = nextPageToken
        self.newStartPageToken = newStartPageToken
    }
}

public struct GoogleDocTabContent: Codable, Sendable, Equatable, Hashable {
    public var tabId: String
    public var title: String
    public var index: Int
    public var markdownOrStructuredText: String
    public var childTabs: [GoogleDocTabContent]

    public init(
        tabId: String,
        title: String,
        index: Int = 0,
        markdownOrStructuredText: String,
        childTabs: [GoogleDocTabContent] = []
    ) {
        self.tabId = tabId
        self.title = title
        self.index = index
        self.markdownOrStructuredText = markdownOrStructuredText
        self.childTabs = childTabs
    }
}

public struct GoogleDocsStructuredDocument: Codable, Sendable, Equatable, Hashable {
    public var documentId: String
    public var title: String
    public var tabs: [GoogleDocTabContent]
    public var isPartiallyTruncated: Bool
    public var warningMessage: String?

    public init(
        documentId: String,
        title: String,
        tabs: [GoogleDocTabContent],
        isPartiallyTruncated: Bool = false,
        warningMessage: String? = nil
    ) {
        self.documentId = documentId
        self.title = title
        self.tabs = tabs
        self.isPartiallyTruncated = isPartiallyTruncated
        self.warningMessage = warningMessage
    }
}

// MARK: - APIエラー分類

public enum GoogleDriveAPIError: Error, Sendable, Equatable, LocalizedError {
    case unauthorized(String)
    case invalidGrant(String)
    case permissionDenied(fileId: String, message: String)
    case forbiddenPermission(String)
    case rateLimited(retryAfterSeconds: Double)
    case notFound(fileId: String)
    case exportSizeLimitExceeded(fileId: String)
    case invalidPageToken(String)
    case invalidSyncPageToken(String)
    case serverError(statusCode: Int, message: String)
    case networkOffline(String)
    case timeout(String)
    case malformedResponse(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let msg): "Google認証エラー (401): \(msg)"
        case .invalidGrant(let msg): "無効な認可コード/リフレッシュトークン (invalid_grant): \(msg)"
        case .permissionDenied(let fid, let msg): "アクセス権限不足 (403) [\(fid)]: \(msg)"
        case .forbiddenPermission(let msg): "アクセス権限喪失 (403): \(msg)"
        case .rateLimited(let sec): "レート制限 (429): \(sec)秒後に再試行してください"
        case .notFound(let fid): "ファイルが見つかりません (404) [\(fid)]"
        case .exportSizeLimitExceeded(let fid): "エクスポートサイズ上限超過 [\(fid)]"
        case .invalidPageToken(let msg), .invalidSyncPageToken(let msg): "Changes APIページトークン失効: \(msg)"
        case .serverError(let code, let msg): "Google API一時障害 (\(code)): \(msg)"
        case .networkOffline(let msg): "ネットワーク未接続: \(msg)"
        case .timeout(let msg): "通信タイムアウト: \(msg)"
        case .malformedResponse(let msg): "不正なレスポンス: \(msg)"
        }
    }
}

// MARK: - 設定・進捗モデル

public struct GoogleDriveSyncConfiguration: Codable, Sendable, Equatable {
    public var syncIntervalMinutes: Int
    public var maxConcurrentDocumentFetches: Int
    public var maxRetryAttempts: Int
    public var initialBackoffMilliseconds: UInt64
    public var fullRescanIntervalHours: Int
    public var isPaused: Bool

    public init(
        syncIntervalMinutes: Int = 5,
        maxConcurrentDocumentFetches: Int = 3,
        maxRetryAttempts: Int = 4,
        initialBackoffMilliseconds: UInt64 = 100,
        fullRescanIntervalHours: Int = 24,
        isPaused: Bool = false
    ) {
        self.syncIntervalMinutes = max(1, min(60, syncIntervalMinutes))
        self.maxConcurrentDocumentFetches = max(1, min(8, maxConcurrentDocumentFetches))
        self.maxRetryAttempts = max(1, maxRetryAttempts)
        self.initialBackoffMilliseconds = initialBackoffMilliseconds
        self.fullRescanIntervalHours = max(1, fullRescanIntervalHours)
        self.isPaused = isPaused
    }
}

public struct GoogleDriveSyncProgress: Codable, Sendable, Equatable {
    public var phaseDescription: String
    public var processedDocuments: Int
    public var totalDocuments: Int
    public var currentDocumentTitle: String?

    public init(
        phaseDescription: String = "",
        processedDocuments: Int = 0,
        totalDocuments: Int = 0,
        currentDocumentTitle: String? = nil
    ) {
        self.phaseDescription = phaseDescription
        self.processedDocuments = processedDocuments
        self.totalDocuments = totalDocuments
        self.currentDocumentTitle = currentDocumentTitle
    }
}
