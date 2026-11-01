import AppKit
import CryptoKit
import Foundation
import Network
import SQLite3

private let SQLITE_TRANSIENT_GD = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - §6 Google Drive 同期用 SQLite リポジトリ (`GoogleDriveSyncRepository`)

public final class GoogleDriveSyncRepository: @unchecked Sendable {
    public let database: LocalDatabase

    public init(database: LocalDatabase) throws {
        self.database = database
        try Self.createTablesAndIndexes(in: database)
    }

    public static func createTablesAndIndexes(in database: LocalDatabase) throws {
        let ddl = """
        CREATE TABLE IF NOT EXISTS google_accounts (
            id TEXT PRIMARY KEY,
            email TEXT NOT NULL,
            display_name TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT 'connected',
            connected_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS google_sync_folders (
            id TEXT PRIMARY KEY,
            account_id TEXT NOT NULL,
            folder_id TEXT NOT NULL,
            folder_name TEXT NOT NULL,
            folder_path TEXT NOT NULL DEFAULT '',
            drive_type TEXT NOT NULL DEFAULT 'my_drive',
            drive_id TEXT,
            include_subfolders INTEGER NOT NULL DEFAULT 1,
            sync_enabled INTEGER NOT NULL DEFAULT 1,
            sync_status TEXT NOT NULL DEFAULT 'idle',
            last_synced_at REAL,
            last_full_scan_at REAL,
            last_error_message TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(account_id, folder_id)
        );

        CREATE TABLE IF NOT EXISTS google_folder_tree (
            account_id TEXT NOT NULL,
            folder_id TEXT NOT NULL,
            parent_folder_id TEXT,
            root_sync_folder_id TEXT NOT NULL,
            folder_name TEXT NOT NULL,
            trashed INTEGER NOT NULL DEFAULT 0,
            updated_at REAL NOT NULL,
            PRIMARY KEY (account_id, folder_id, root_sync_folder_id)
        );

        CREATE TABLE IF NOT EXISTS external_documents (
            id TEXT PRIMARY KEY,
            document_id TEXT NOT NULL,
            provider TEXT NOT NULL DEFAULT 'google_drive',
            account_id TEXT NOT NULL,
            external_file_id TEXT NOT NULL,
            parent_folder_id TEXT,
            mime_type TEXT NOT NULL,
            web_view_link TEXT NOT NULL DEFAULT '',
            remote_modified_time TEXT NOT NULL,
            remote_version TEXT,
            content_hash TEXT NOT NULL DEFAULT '',
            sync_status TEXT NOT NULL DEFAULT 'synced',
            last_synced_at REAL,
            last_error_message TEXT,
            UNIQUE(account_id, external_file_id)
        );

        CREATE TABLE IF NOT EXISTS google_document_memberships (
            account_id TEXT NOT NULL,
            external_file_id TEXT NOT NULL,
            sync_folder_id TEXT NOT NULL,
            folder_id TEXT NOT NULL,
            is_active INTEGER NOT NULL DEFAULT 1,
            updated_at REAL NOT NULL,
            PRIMARY KEY (account_id, external_file_id, sync_folder_id)
        );

        CREATE TABLE IF NOT EXISTS google_sync_cursors (
            account_id TEXT NOT NULL,
            scope_key TEXT NOT NULL,
            page_token TEXT NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY (account_id, scope_key)
        );

        CREATE TABLE IF NOT EXISTS google_sync_jobs (
            id TEXT PRIMARY KEY,
            account_id TEXT NOT NULL,
            external_file_id TEXT NOT NULL,
            change_type TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            retry_count INTEGER NOT NULL DEFAULT 0,
            last_error_message TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_google_sync_folders_account ON google_sync_folders(account_id);
        CREATE INDEX IF NOT EXISTS idx_google_folder_tree_root ON google_folder_tree(account_id, root_sync_folder_id);
        CREATE INDEX IF NOT EXISTS idx_external_documents_account_file ON external_documents(account_id, external_file_id);
        CREATE INDEX IF NOT EXISTS idx_external_documents_doc_id ON external_documents(document_id);
        CREATE INDEX IF NOT EXISTS idx_google_doc_memberships_file ON google_document_memberships(account_id, external_file_id);
        CREATE INDEX IF NOT EXISTS idx_google_doc_memberships_sync_folder ON google_document_memberships(sync_folder_id);
        CREATE INDEX IF NOT EXISTS idx_google_sync_jobs_status ON google_sync_jobs(account_id, status, created_at);
        """
        try database.executeRawSQL(ddl)
    }

    // MARK: - §6.2 `google_accounts`

    public func upsertAccount(_ account: GoogleAccountRecord) throws {
        try database.withSQLiteHandle { db in
            let sql = """
            INSERT INTO google_accounts (id, email, display_name, status, connected_at, updated_at)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(id) DO UPDATE SET
                email = excluded.email,
                display_name = excluded.display_name,
                status = excluded.status,
                updated_at = excluded.updated_at;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, account.id, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 2, account.email, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 3, account.displayName, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 4, account.status.rawValue, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_double(stmt, 5, account.connectedAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 6, account.updatedAt.timeIntervalSince1970)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw DatabaseError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func fetchAccounts() throws -> [GoogleAccountRecord] {
        try database.withSQLiteHandle { db in
            let sql = "SELECT id, email, display_name, status, connected_at, updated_at FROM google_accounts ORDER BY connected_at ASC;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            var results: [GoogleAccountRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let email = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let name = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let statusRaw = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "connected"
                let cAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                let uAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
                results.append(GoogleAccountRecord(
                    id: id,
                    email: email,
                    displayName: name,
                    status: GoogleAccountStatus(rawValue: statusRaw) ?? .connected,
                    connectedAt: cAt,
                    updatedAt: uAt
                ))
            }
            return results
        }
    }

    public func fetchAccount(id: String) throws -> GoogleAccountRecord? {
        try fetchAccounts().first(where: { $0.id == id })
    }

    public func deleteAccountData(accountId: String) throws {
        try database.withSQLiteHandle { db in
            for (table, col) in [
                ("google_sync_jobs", "account_id"),
                ("google_sync_cursors", "account_id"),
                ("google_document_memberships", "account_id"),
                ("external_documents", "account_id"),
                ("google_folder_tree", "account_id"),
                ("google_sync_folders", "account_id"),
                ("google_accounts", "id")
            ] {
                let sql = "DELETE FROM \(table) WHERE \(col) = ?1;"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, accountId, -1, SQLITE_TRANSIENT_GD)
                    _ = sqlite3_step(stmt)
                    sqlite3_finalize(stmt)
                }
            }
        }
    }

    // MARK: - §6.3 `google_sync_folders`

    public func upsertSyncFolder(_ folder: GoogleSyncFolderRecord) throws {
        try database.withSQLiteHandle { db in
            let sql = """
            INSERT INTO google_sync_folders (
                id, account_id, folder_id, folder_name, folder_path, drive_type, drive_id,
                include_subfolders, sync_enabled, sync_status, last_synced_at, last_full_scan_at,
                last_error_message, created_at, updated_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15)
            ON CONFLICT(id) DO UPDATE SET
                folder_name = excluded.folder_name,
                folder_path = excluded.folder_path,
                drive_type = excluded.drive_type,
                drive_id = excluded.drive_id,
                include_subfolders = excluded.include_subfolders,
                sync_enabled = excluded.sync_enabled,
                sync_status = excluded.sync_status,
                last_synced_at = excluded.last_synced_at,
                last_full_scan_at = excluded.last_full_scan_at,
                last_error_message = excluded.last_error_message,
                updated_at = excluded.updated_at;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, folder.id, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 2, folder.accountId, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 3, folder.folderId, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 4, folder.folderName, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 5, folder.folderPath, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 6, folder.driveType.rawValue, -1, SQLITE_TRANSIENT_GD)
            if let driveId = folder.driveId {
                sqlite3_bind_text(stmt, 7, driveId, -1, SQLITE_TRANSIENT_GD)
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            sqlite3_bind_int(stmt, 8, folder.includeSubfolders ? 1 : 0)
            sqlite3_bind_int(stmt, 9, folder.syncEnabled ? 1 : 0)
            sqlite3_bind_text(stmt, 10, folder.syncStatus.rawValue, -1, SQLITE_TRANSIENT_GD)
            if let lSync = folder.lastSyncedAt {
                sqlite3_bind_double(stmt, 11, lSync.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 11)
            }
            if let lFull = folder.lastFullScanAt {
                sqlite3_bind_double(stmt, 12, lFull.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 12)
            }
            if let err = folder.lastErrorMessage {
                sqlite3_bind_text(stmt, 13, err, -1, SQLITE_TRANSIENT_GD)
            } else {
                sqlite3_bind_null(stmt, 13)
            }
            sqlite3_bind_double(stmt, 14, folder.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 15, folder.updatedAt.timeIntervalSince1970)

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw DatabaseError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func fetchSyncFolders(accountId: String? = nil) throws -> [GoogleSyncFolderRecord] {
        try database.withSQLiteHandle { db in
            let sql: String
            if accountId != nil {
                sql = """
                SELECT id, account_id, folder_id, folder_name, folder_path, drive_type, drive_id,
                       include_subfolders, sync_enabled, sync_status, last_synced_at, last_full_scan_at,
                       last_error_message, created_at, updated_at
                FROM google_sync_folders
                WHERE account_id = ?1
                ORDER BY created_at ASC;
                """
            } else {
                sql = """
                SELECT id, account_id, folder_id, folder_name, folder_path, drive_type, drive_id,
                       include_subfolders, sync_enabled, sync_status, last_synced_at, last_full_scan_at,
                       last_error_message, created_at, updated_at
                FROM google_sync_folders
                ORDER BY created_at ASC;
                """
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            if let accountId {
                sqlite3_bind_text(stmt, 1, accountId, -1, SQLITE_TRANSIENT_GD)
            }
            var list: [GoogleSyncFolderRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let accId = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let fId = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let fName = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                let fPath = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                let dTypeRaw = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "my_drive"
                let dId: String? = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_text(stmt, 6).map { String(cString: $0) }
                let incSub = sqlite3_column_int(stmt, 7) != 0
                let enabled = sqlite3_column_int(stmt, 8) != 0
                let statusRaw = sqlite3_column_text(stmt, 9).map { String(cString: $0) } ?? "idle"
                let lSync: Date? = sqlite3_column_type(stmt, 10) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))
                let lFull: Date? = sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11))
                let errMsg: String? = sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : sqlite3_column_text(stmt, 12).map { String(cString: $0) }
                let cAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13))
                let uAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 14))

                list.append(GoogleSyncFolderRecord(
                    id: id,
                    accountId: accId,
                    folderId: fId,
                    folderName: fName,
                    folderPath: fPath,
                    driveType: GoogleDriveLocationType(rawValue: dTypeRaw) ?? .myDrive,
                    driveId: dId,
                    includeSubfolders: incSub,
                    syncEnabled: enabled,
                    syncStatus: GoogleSyncFolderStatus(rawValue: statusRaw) ?? .idle,
                    lastSyncedAt: lSync,
                    lastFullScanAt: lFull,
                    lastErrorMessage: errMsg,
                    createdAt: cAt,
                    updatedAt: uAt
                ))
            }
            return list
        }
    }

    public func deleteSyncFolder(id: String) throws {
        try database.withSQLiteHandle { db in
            let sql = "DELETE FROM google_sync_folders WHERE id = ?1;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT_GD)
                _ = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    // MARK: - §6.4 `google_folder_tree`

    public func upsertFolderTreeNode(_ node: GoogleFolderTreeNodeRecord) throws {
        try database.withSQLiteHandle { db in
            let sql = """
            INSERT INTO google_folder_tree (
                account_id, folder_id, parent_folder_id, root_sync_folder_id, folder_name, trashed, updated_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ON CONFLICT(account_id, folder_id, root_sync_folder_id) DO UPDATE SET
                parent_folder_id = excluded.parent_folder_id,
                folder_name = excluded.folder_name,
                trashed = excluded.trashed,
                updated_at = excluded.updated_at;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, node.accountId, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 2, node.folderId, -1, SQLITE_TRANSIENT_GD)
            if let parentId = node.parentFolderId {
                sqlite3_bind_text(stmt, 3, parentId, -1, SQLITE_TRANSIENT_GD)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_text(stmt, 4, node.rootSyncFolderId, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 5, node.folderName, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_int(stmt, 6, node.trashed ? 1 : 0)
            sqlite3_bind_double(stmt, 7, node.updatedAt.timeIntervalSince1970)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw DatabaseError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func fetchFolderTreeNodes(accountId: String, rootSyncFolderId: String? = nil) throws -> [GoogleFolderTreeNodeRecord] {
        try database.withSQLiteHandle { db in
            let sql: String
            if rootSyncFolderId != nil {
                sql = """
                SELECT account_id, folder_id, parent_folder_id, root_sync_folder_id, folder_name, trashed, updated_at
                FROM google_folder_tree
                WHERE account_id = ?1 AND root_sync_folder_id = ?2;
                """
            } else {
                sql = """
                SELECT account_id, folder_id, parent_folder_id, root_sync_folder_id, folder_name, trashed, updated_at
                FROM google_folder_tree
                WHERE account_id = ?1;
                """
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, accountId, -1, SQLITE_TRANSIENT_GD)
            if let rootSyncFolderId {
                sqlite3_bind_text(stmt, 2, rootSyncFolderId, -1, SQLITE_TRANSIENT_GD)
            }
            var nodes: [GoogleFolderTreeNodeRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let accId = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let fId = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let pId: String? = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_text(stmt, 2).map { String(cString: $0) }
                let rootId = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                let fName = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                let trashed = sqlite3_column_int(stmt, 5) != 0
                let uAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                nodes.append(GoogleFolderTreeNodeRecord(
                    accountId: accId,
                    folderId: fId,
                    parentFolderId: pId,
                    rootSyncFolderId: rootId,
                    folderName: fName,
                    trashed: trashed,
                    updatedAt: uAt
                ))
            }
            return nodes
        }
    }

    public func deleteFolderTreeForSyncFolder(accountId: String, rootSyncFolderId: String) throws {
        try database.withSQLiteHandle { db in
            let sql = "DELETE FROM google_folder_tree WHERE account_id = ?1 AND root_sync_folder_id = ?2;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, accountId, -1, SQLITE_TRANSIENT_GD)
                sqlite3_bind_text(stmt, 2, rootSyncFolderId, -1, SQLITE_TRANSIENT_GD)
                _ = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    public func deleteFolderTreeSubtree(accountId: String, folderIds: Set<String>, rootSyncFolderId: String? = nil) throws {
        guard !folderIds.isEmpty else { return }
        try database.withSQLiteHandle { db in
            for fId in folderIds {
                let sql: String
                if rootSyncFolderId != nil {
                    sql = "DELETE FROM google_folder_tree WHERE account_id = ?1 AND folder_id = ?2 AND root_sync_folder_id = ?3;"
                } else {
                    sql = "DELETE FROM google_folder_tree WHERE account_id = ?1 AND folder_id = ?2;"
                }
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, accountId, -1, SQLITE_TRANSIENT_GD)
                    sqlite3_bind_text(stmt, 2, fId, -1, SQLITE_TRANSIENT_GD)
                    if let rootSyncFolderId {
                        sqlite3_bind_text(stmt, 3, rootSyncFolderId, -1, SQLITE_TRANSIENT_GD)
                    }
                    _ = sqlite3_step(stmt)
                    sqlite3_finalize(stmt)
                }
            }
        }
    }

    // MARK: - §6.5 `external_documents`

    public func upsertExternalDocument(_ record: ExternalDocumentRecord) throws {
        try database.withSQLiteHandle { db in
            let sql = """
            INSERT INTO external_documents (
                id, document_id, provider, account_id, external_file_id, parent_folder_id,
                mime_type, web_view_link, remote_modified_time, remote_version, content_hash,
                sync_status, last_synced_at, last_error_message
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)
            ON CONFLICT(account_id, external_file_id) DO UPDATE SET
                document_id = excluded.document_id,
                parent_folder_id = excluded.parent_folder_id,
                mime_type = excluded.mime_type,
                web_view_link = excluded.web_view_link,
                remote_modified_time = excluded.remote_modified_time,
                remote_version = excluded.remote_version,
                content_hash = excluded.content_hash,
                sync_status = excluded.sync_status,
                last_synced_at = excluded.last_synced_at,
                last_error_message = excluded.last_error_message;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, record.id, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 2, record.documentId, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 3, record.provider, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 4, record.accountId, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 5, record.externalFileId, -1, SQLITE_TRANSIENT_GD)
            if let pId = record.parentFolderId {
                sqlite3_bind_text(stmt, 6, pId, -1, SQLITE_TRANSIENT_GD)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            sqlite3_bind_text(stmt, 7, record.mimeType, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 8, record.webViewLink, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 9, record.remoteModifiedTime, -1, SQLITE_TRANSIENT_GD)
            if let rVer = record.remoteVersion {
                sqlite3_bind_text(stmt, 10, rVer, -1, SQLITE_TRANSIENT_GD)
            } else {
                sqlite3_bind_null(stmt, 10)
            }
            sqlite3_bind_text(stmt, 11, record.contentHash, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 12, record.syncStatus.rawValue, -1, SQLITE_TRANSIENT_GD)
            if let lSync = record.lastSyncedAt {
                sqlite3_bind_double(stmt, 13, lSync.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 13)
            }
            if let err = record.lastErrorMessage {
                sqlite3_bind_text(stmt, 14, err, -1, SQLITE_TRANSIENT_GD)
            } else {
                sqlite3_bind_null(stmt, 14)
            }

            if sqlite3_step(stmt) != SQLITE_DONE {
                throw DatabaseError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func fetchExternalDocument(accountId: String, externalFileId: String) throws -> ExternalDocumentRecord? {
        try fetchExternalDocuments(accountId: accountId).first { $0.externalFileId == externalFileId }
    }

    public func fetchExternalDocuments(accountId: String? = nil) throws -> [ExternalDocumentRecord] {
        try database.withSQLiteHandle { db in
            let sql: String
            if accountId != nil {
                sql = """
                SELECT id, document_id, provider, account_id, external_file_id, parent_folder_id,
                       mime_type, web_view_link, remote_modified_time, remote_version, content_hash,
                       sync_status, last_synced_at, last_error_message
                FROM external_documents
                WHERE account_id = ?1
                ORDER BY last_synced_at DESC;
                """
            } else {
                sql = """
                SELECT id, document_id, provider, account_id, external_file_id, parent_folder_id,
                       mime_type, web_view_link, remote_modified_time, remote_version, content_hash,
                       sync_status, last_synced_at, last_error_message
                FROM external_documents
                ORDER BY last_synced_at DESC;
                """
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            if let accountId {
                sqlite3_bind_text(stmt, 1, accountId, -1, SQLITE_TRANSIENT_GD)
            }
            var records: [ExternalDocumentRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let docId = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let prov = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? "google_drive"
                let accId = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                let extId = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                let pId: String? = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                let mime = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? ""
                let link = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? ""
                let rMod = sqlite3_column_text(stmt, 8).map { String(cString: $0) } ?? ""
                let rVer: String? = sqlite3_column_type(stmt, 9) == SQLITE_NULL ? nil : sqlite3_column_text(stmt, 9).map { String(cString: $0) }
                let cHash = sqlite3_column_text(stmt, 10).map { String(cString: $0) } ?? ""
                let stRaw = sqlite3_column_text(stmt, 11).map { String(cString: $0) } ?? "synced"
                let lSync: Date? = sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12))
                let err: String? = sqlite3_column_type(stmt, 13) == SQLITE_NULL ? nil : sqlite3_column_text(stmt, 13).map { String(cString: $0) }

                records.append(ExternalDocumentRecord(
                    id: id,
                    documentId: docId,
                    provider: prov,
                    accountId: accId,
                    externalFileId: extId,
                    parentFolderId: pId,
                    mimeType: mime,
                    webViewLink: link,
                    remoteModifiedTime: rMod,
                    remoteVersion: rVer,
                    contentHash: cHash,
                    syncStatus: ExternalDocumentSyncStatus(rawValue: stRaw) ?? .synced,
                    lastSyncedAt: lSync,
                    lastErrorMessage: err
                ))
            }
            return records
        }
    }

    public func deleteExternalDocument(accountId: String, externalFileId: String) throws {
        try database.withSQLiteHandle { db in
            let sql = "DELETE FROM external_documents WHERE account_id = ?1 AND external_file_id = ?2;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, accountId, -1, SQLITE_TRANSIENT_GD)
                sqlite3_bind_text(stmt, 2, externalFileId, -1, SQLITE_TRANSIENT_GD)
                _ = sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }
        }
    }

    // MARK: - §6.6 `google_document_memberships`

    public func upsertMembership(_ membership: GoogleDocumentMembershipRecord) throws {
        try database.withSQLiteHandle { db in
            let sql = """
            INSERT INTO google_document_memberships (
                account_id, external_file_id, sync_folder_id, folder_id, is_active, updated_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            ON CONFLICT(account_id, external_file_id, sync_folder_id) DO UPDATE SET
                folder_id = excluded.folder_id,
                is_active = excluded.is_active,
                updated_at = excluded.updated_at;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, membership.accountId, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 2, membership.externalFileId, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 3, membership.syncFolderId, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 4, membership.folderId, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_int(stmt, 5, membership.isActive ? 1 : 0)
            sqlite3_bind_double(stmt, 6, membership.updatedAt.timeIntervalSince1970)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw DatabaseError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func fetchMemberships(
        accountId: String,
        externalFileId: String? = nil,
        syncFolderId: String? = nil,
        onlyActive: Bool = true
    ) throws -> [GoogleDocumentMembershipRecord] {
        try database.withSQLiteHandle { db in
            var sql = """
            SELECT account_id, external_file_id, sync_folder_id, folder_id, is_active, updated_at
            FROM google_document_memberships
            WHERE account_id = ?1
            """
            if onlyActive {
                sql += " AND is_active = 1"
            }
            sql += ";"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, accountId, -1, SQLITE_TRANSIENT_GD)

            var items: [GoogleDocumentMembershipRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let acc = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let extId = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let syncFId = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let fId = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                let active = sqlite3_column_int(stmt, 4) != 0
                let uAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))

                if let externalFileId, extId != externalFileId { continue }
                if let syncFolderId, syncFId != syncFolderId { continue }
                items.append(GoogleDocumentMembershipRecord(
                    accountId: acc,
                    externalFileId: extId,
                    syncFolderId: syncFId,
                    folderId: fId,
                    isActive: active,
                    updatedAt: uAt
                ))
            }
            return items
        }
    }

    public func deleteMemberships(accountId: String, externalFileId: String? = nil, syncFolderId: String? = nil) throws {
        try database.withSQLiteHandle { db in
            if let externalFileId, let syncFolderId {
                let sql = "DELETE FROM google_document_memberships WHERE account_id = ?1 AND external_file_id = ?2 AND sync_folder_id = ?3;"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, accountId, -1, SQLITE_TRANSIENT_GD)
                    sqlite3_bind_text(stmt, 2, externalFileId, -1, SQLITE_TRANSIENT_GD)
                    sqlite3_bind_text(stmt, 3, syncFolderId, -1, SQLITE_TRANSIENT_GD)
                    _ = sqlite3_step(stmt)
                    sqlite3_finalize(stmt)
                }
            } else if let externalFileId {
                let sql = "DELETE FROM google_document_memberships WHERE account_id = ?1 AND external_file_id = ?2;"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, accountId, -1, SQLITE_TRANSIENT_GD)
                    sqlite3_bind_text(stmt, 2, externalFileId, -1, SQLITE_TRANSIENT_GD)
                    _ = sqlite3_step(stmt)
                    sqlite3_finalize(stmt)
                }
            } else if let syncFolderId {
                let sql = "DELETE FROM google_document_memberships WHERE account_id = ?1 AND sync_folder_id = ?2;"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, accountId, -1, SQLITE_TRANSIENT_GD)
                    sqlite3_bind_text(stmt, 2, syncFolderId, -1, SQLITE_TRANSIENT_GD)
                    _ = sqlite3_step(stmt)
                    sqlite3_finalize(stmt)
                }
            }
        }
    }

    // MARK: - §6.7 `google_sync_cursors` & §6.8 `google_sync_jobs`

    public func upsertSyncCursor(_ cursor: GoogleSyncCursorRecord) throws {
        try database.withSQLiteHandle { db in
            let sql = """
            INSERT INTO google_sync_cursors (account_id, scope_key, page_token, updated_at)
            VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT(account_id, scope_key) DO UPDATE SET
                page_token = excluded.page_token,
                updated_at = excluded.updated_at;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, cursor.accountId, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 2, cursor.scopeKey, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 3, cursor.pageToken, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_double(stmt, 4, cursor.updatedAt.timeIntervalSince1970)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw DatabaseError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func fetchSyncCursor(accountId: String, scopeKey: String = "default") throws -> GoogleSyncCursorRecord? {
        try database.withSQLiteHandle { db in
            let sql = "SELECT account_id, scope_key, page_token, updated_at FROM google_sync_cursors WHERE account_id = ?1 AND scope_key = ?2 LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, accountId, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 2, scopeKey, -1, SQLITE_TRANSIENT_GD)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let acc = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? accountId
            let scope = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? scopeKey
            let tok = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let uAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            return GoogleSyncCursorRecord(accountId: acc, scopeKey: scope, pageToken: tok, updatedAt: uAt)
        }
    }

    /// §5.2 Changes API の全ページ取得後、`google_sync_jobs` への登録（同一ファイル連続変更の統合 Coalescing 含む）と `google_sync_cursors` (`newStartPageToken`) の更新を同一トランザクションで行う
    public func enqueueChangeJobsAndAdvanceCursorAtomically(
        accountId: String,
        scopeKey: String = "default",
        changes: [GoogleDriveChangeItem],
        newStartPageToken: String
    ) throws -> [GoogleSyncJobRecord] {
        // 同一ファイル (`fileId`) に対する連続変更は最後の状態へ統合 (Coalesce) する (§5.2)
        var coalescedByFileId: [String: GoogleDriveChangeItem] = [:]
        var orderedFileIds: [String] = []
        for change in changes {
            if coalescedByFileId[change.fileId] == nil {
                orderedFileIds.append(change.fileId)
            }
            coalescedByFileId[change.fileId] = change
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let now = Date()
        var createdJobs: [GoogleSyncJobRecord] = []

        try database.withTransaction { db in
            // 既存の未完了 (pending) ジョブで同一 fileId のものがあれば統合更新または置換する
            let deleteOldPendingSql = "DELETE FROM google_sync_jobs WHERE account_id = ?1 AND external_file_id = ?2 AND status = 'pending';"
            let insertJobSql = """
            INSERT INTO google_sync_jobs (
                id, account_id, external_file_id, change_type, payload_json, status, retry_count, last_error_message, created_at, updated_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10);
            """

            for fileId in orderedFileIds {
                guard let change = coalescedByFileId[fileId] else { continue }
                let changeType: GoogleSyncJobChangeType
                if change.removed || change.file?.trashed == true {
                    changeType = .remove
                } else if change.file?.isFolder == true {
                    changeType = .folderChange
                } else {
                    changeType = .upsert
                }

                let payloadData = (try? encoder.encode(change)) ?? Data()
                let payloadJson = String(data: payloadData, encoding: .utf8) ?? "{}"
                let job = GoogleSyncJobRecord(
                    id: UUID().uuidString,
                    accountId: accountId,
                    externalFileId: fileId,
                    changeType: changeType,
                    payloadJSON: payloadJson,
                    status: .pending,
                    retryCount: 0,
                    lastErrorMessage: nil,
                    createdAt: now,
                    updatedAt: now
                )

                var delStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, deleteOldPendingSql, -1, &delStmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(delStmt, 1, accountId, -1, SQLITE_TRANSIENT_GD)
                    sqlite3_bind_text(delStmt, 2, fileId, -1, SQLITE_TRANSIENT_GD)
                    _ = sqlite3_step(delStmt)
                    sqlite3_finalize(delStmt)
                }

                var insStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, insertJobSql, -1, &insStmt, nil) == SQLITE_OK else {
                    throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
                }
                defer { sqlite3_finalize(insStmt) }
                sqlite3_bind_text(insStmt, 1, job.id, -1, SQLITE_TRANSIENT_GD)
                sqlite3_bind_text(insStmt, 2, job.accountId, -1, SQLITE_TRANSIENT_GD)
                sqlite3_bind_text(insStmt, 3, job.externalFileId, -1, SQLITE_TRANSIENT_GD)
                sqlite3_bind_text(insStmt, 4, job.changeType.rawValue, -1, SQLITE_TRANSIENT_GD)
                sqlite3_bind_text(insStmt, 5, job.payloadJSON, -1, SQLITE_TRANSIENT_GD)
                sqlite3_bind_text(insStmt, 6, job.status.rawValue, -1, SQLITE_TRANSIENT_GD)
                sqlite3_bind_int(insStmt, 7, Int32(job.retryCount))
                sqlite3_bind_null(insStmt, 8)
                sqlite3_bind_double(insStmt, 9, job.createdAt.timeIntervalSince1970)
                sqlite3_bind_double(insStmt, 10, job.updatedAt.timeIntervalSince1970)
                if sqlite3_step(insStmt) != SQLITE_DONE {
                    throw DatabaseError.executionFailed(String(cString: sqlite3_errmsg(db)))
                }
                createdJobs.append(job)
            }

            // 同一トランザクション内で `google_sync_cursors` (`newStartPageToken`) を更新
            let cursorSql = """
            INSERT INTO google_sync_cursors (account_id, scope_key, page_token, updated_at)
            VALUES (?1, ?2, ?3, ?4)
            ON CONFLICT(account_id, scope_key) DO UPDATE SET
                page_token = excluded.page_token,
                updated_at = excluded.updated_at;
            """
            var curStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, cursorSql, -1, &curStmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(curStmt) }
            sqlite3_bind_text(curStmt, 1, accountId, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(curStmt, 2, scopeKey, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(curStmt, 3, newStartPageToken, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_double(curStmt, 4, now.timeIntervalSince1970)
            if sqlite3_step(curStmt) != SQLITE_DONE {
                throw DatabaseError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
        }

        return createdJobs
    }

    public func upsertSyncJob(_ job: GoogleSyncJobRecord) throws {
        try database.withSQLiteHandle { db in
            let sql = """
            INSERT INTO google_sync_jobs (
                id, account_id, external_file_id, change_type, payload_json, status, retry_count, last_error_message, created_at, updated_at
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            ON CONFLICT(id) DO UPDATE SET
                status = excluded.status,
                retry_count = excluded.retry_count,
                last_error_message = excluded.last_error_message,
                updated_at = excluded.updated_at;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, job.id, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 2, job.accountId, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 3, job.externalFileId, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 4, job.changeType.rawValue, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 5, job.payloadJSON, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_text(stmt, 6, job.status.rawValue, -1, SQLITE_TRANSIENT_GD)
            sqlite3_bind_int(stmt, 7, Int32(job.retryCount))
            if let err = job.lastErrorMessage {
                sqlite3_bind_text(stmt, 8, err, -1, SQLITE_TRANSIENT_GD)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            sqlite3_bind_double(stmt, 9, job.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 10, job.updatedAt.timeIntervalSince1970)
            if sqlite3_step(stmt) != SQLITE_DONE {
                throw DatabaseError.executionFailed(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    public func fetchSyncJobs(accountId: String? = nil, statuses: [GoogleSyncJobStatus]? = nil) throws -> [GoogleSyncJobRecord] {
        try database.withSQLiteHandle { db in
            let sql = """
            SELECT id, account_id, external_file_id, change_type, payload_json, status, retry_count, last_error_message, created_at, updated_at
            FROM google_sync_jobs
            ORDER BY created_at ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw DatabaseError.prepareFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(stmt) }
            var jobs: [GoogleSyncJobRecord] = []
            let statusSet = statuses.map(Set.init)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let acc = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
                let extId = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                let cType = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "upsert"
                let payload = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "{}"
                let stRaw = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "pending"
                let retries = Int(sqlite3_column_int(stmt, 6))
                let err: String? = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : sqlite3_column_text(stmt, 7).map { String(cString: $0) }
                let cAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
                let uAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))

                if let accountId, acc != accountId { continue }
                let st = GoogleSyncJobStatus(rawValue: stRaw) ?? .pending
                if let statusSet, !statusSet.contains(st) { continue }

                jobs.append(GoogleSyncJobRecord(
                    id: id,
                    accountId: acc,
                    externalFileId: extId,
                    changeType: GoogleSyncJobChangeType(rawValue: cType) ?? .upsert,
                    payloadJSON: payload,
                    status: st,
                    retryCount: retries,
                    lastErrorMessage: err,
                    createdAt: cAt,
                    updatedAt: uAt
                ))
            }
            return jobs
        }
    }
}

// MARK: - Google Drive 自動同期オーケストレーター (`GoogleDriveSyncService`)

@MainActor
public final class GoogleDriveSyncService: ObservableObject {
    @Published public private(set) var accounts: [GoogleAccountRecord] = []
    @Published public private(set) var syncFolders: [GoogleSyncFolderRecord] = []
    @Published public private(set) var externalDocuments: [ExternalDocumentRecord] = []
    @Published public private(set) var availableRemoteFolders: [GoogleDriveFileItem] = []
    @Published public private(set) var syncState: GoogleDriveSyncState = .idle
    @Published public private(set) var syncProgress: GoogleDriveSyncProgress?
    @Published public var configuration: GoogleDriveSyncConfiguration
    @Published public private(set) var lastSyncedAt: Date?
    @Published public private(set) var lastErrorMessage: String?
    @Published public private(set) var lastPKCEChallenge: PKCECodeChallengeGenerator?
    @Published public private(set) var lastAuthorizationURL: URL?

    public let syncRepository: GoogleDriveSyncRepository
    public let documentRepository: DocumentRepository
    public let indexManager: IndexManager
    public let tokenStore: any GoogleOAuthTokenStore
    public var apiClient: any GoogleDriveAPIClientProtocol
    public let jobManager: JobManager

    /// Embedding アダプタ解決クロージャ
    public var embeddingAdapterProvider: () -> any EmbeddingAdapter

    /// テスト用：特定ファイルIDのインデックス生成で強制エラーを発生させる（§11.3 旧正常インデックス保護検証用）
    public var failingIndexingExternalFileIdsForTesting: Set<String> = []
    /// テスト用：指定件数のジョブを処理した時点で中断をシミュレートする（§13.3 同期中のアプリ終了からの再開検証用）
    public var maxJobsToProcessBeforeSimulatedInterrupt: Int?

    private var periodicSyncTimer: Timer?
    private var sleepWakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "com.mnemosift.googledrive.network", qos: .utility)
    private var lastTriggerTimestamp: Date = .distantPast
    private var isExecutingSync: Bool = false

    public static let oauthClientId = "mnemosift-macos-desktop.apps.googleusercontent.com"
    public static let oauthRedirectURI = "com.mnemosift.app:/oauth2redirect"

    public init(
        database: LocalDatabase,
        documentRepository: DocumentRepository,
        indexManager: IndexManager,
        tokenStore: any GoogleOAuthTokenStore = InMemoryKeychainTokenStore(),
        apiClient: any GoogleDriveAPIClientProtocol = ControllableGoogleDriveAPIClient(),
        jobManager: JobManager,
        configuration: GoogleDriveSyncConfiguration = GoogleDriveSyncConfiguration(),
        embeddingAdapterProvider: @escaping () -> any EmbeddingAdapter
    ) throws {
        self.syncRepository = try GoogleDriveSyncRepository(database: database)
        self.documentRepository = documentRepository
        self.indexManager = indexManager
        self.tokenStore = tokenStore
        self.apiClient = apiClient
        self.jobManager = jobManager
        self.configuration = configuration
        self.embeddingAdapterProvider = embeddingAdapterProvider

        reloadStateFromDatabase()
        setupSystemEventMonitors()
        reschedulePeriodicSyncTimer()
    }

    isolated deinit {
        periodicSyncTimer?.invalidate()
        if let sleepWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepWakeObserver)
        }
        pathMonitor?.cancel()
    }

    public func reloadStateFromDatabase() {
        self.accounts = (try? syncRepository.fetchAccounts()) ?? []
        self.syncFolders = (try? syncRepository.fetchSyncFolders()) ?? []
        self.externalDocuments = (try? syncRepository.fetchExternalDocuments()) ?? []
        self.lastSyncedAt = syncFolders.compactMap(\.lastSyncedAt).max()

        if accounts.contains(where: { $0.status == .authRequired }) {
            self.syncState = .authRequired(lastErrorMessage ?? "Googleアカウントの再認証が必要です。")
        } else if configuration.isPaused {
            self.syncState = .paused
        } else if !isExecutingSync {
            self.syncState = .idle
        }
    }

    // MARK: - §2 Google OAuth 2.0 連携 (PKCE + システムブラウザ + Keychain)

    /// §2.1 PKCE を生成し、システムブラウザ用の Google OAuth 2.0 認可 URL を構築する（openInBrowser=true の場合はシステムブラウザを起動）
    @discardableResult
    public func startOAuthFlowInSystemBrowser(openInBrowser: Bool = true) throws -> (url: URL, pkce: PKCECodeChallengeGenerator) {
        let pkce = PKCECodeChallengeGenerator()
        self.lastPKCEChallenge = pkce
        guard let url = pkce.buildAuthorizationURL(
            clientId: Self.oauthClientId,
            redirectURI: Self.oauthRedirectURI
        ) else {
            throw GoogleDriveAPIError.invalidGrant("OAuth認可URLの生成に失敗しました")
        }
        self.lastAuthorizationURL = url
        if openInBrowser {
            NSWorkspace.shared.open(url)
        }
        return (url, pkce)
    }

    /// §2.1, §2.3, §2.4 OAuth 認可コード（または連携フロー完了）からトークンを Keychain に保存し、アカウントを登録する
    /// - SQLite にはトークンを一切平文保存しない
    /// - 認証情報をログに出力しない
    @discardableResult
    public func connectGoogleAccount(
        authorizationCode: String = "pkce_auth_code_demo",
        codeVerifier: String? = nil,
        openFolderListImmediately: Bool = true
    ) async throws -> GoogleAccountRecord {
        let verifier = codeVerifier ?? lastPKCEChallenge?.codeVerifier ?? PKCECodeChallengeGenerator().codeVerifier
        let exchanged = try await apiClient.exchangeAuthorizationCode(
            code: authorizationCode,
            codeVerifier: verifier,
            clientId: Self.oauthClientId,
            redirectURI: Self.oauthRedirectURI
        )

        // Keychain にトークンを保存 (§2.3)
        try tokenStore.saveTokens(exchanged.token, forAccountId: exchanged.accountId)

        let now = Date()
        let account = GoogleAccountRecord(
            id: exchanged.accountId,
            email: exchanged.email,
            displayName: exchanged.displayName,
            status: .connected,
            connectedAt: now,
            updatedAt: now
        )
        try syncRepository.upsertAccount(account)
        reloadStateFromDatabase()

        if openFolderListImmediately {
            _ = try? await refreshAvailableRemoteFolders(accountId: account.id)
        }
        return account
    }

    /// Keychain から有効なトークンを取得し、期限切れの場合は Refresh Token で更新する (§2.3)
    public func ensureValidToken(forAccountId accountId: String) async throws -> GoogleOAuthTokenBundle {
        guard var bundle = try tokenStore.loadTokens(forAccountId: accountId) else {
            try markAccountAuthRequired(accountId: accountId, message: "Keychainに認証トークンが見つかりません。再認証してください。")
            throw GoogleDriveAPIError.unauthorized("Missing OAuth token in Keychain")
        }

        if bundle.isExpired {
            do {
                bundle = try await apiClient.refreshAccessToken(
                    refreshToken: bundle.refreshToken,
                    clientId: Self.oauthClientId
                )
                try tokenStore.saveTokens(bundle, forAccountId: accountId)
            } catch {
                try markAccountAuthRequired(accountId: accountId, message: "リフレッシュトークンが失効しました。Googleアカウントを再認証してください。")
                throw GoogleDriveAPIError.unauthorized("Refresh token expired or revoked")
            }
        }
        return bundle
    }

    private func markAccountAuthRequired(accountId: String, message: String) throws {
        if var acc = try syncRepository.fetchAccount(id: accountId) {
            acc.status = .authRequired
            acc.updatedAt = Date()
            try syncRepository.upsertAccount(acc)
        }
        let folders = try syncRepository.fetchSyncFolders(accountId: accountId)
        for var folder in folders {
            folder.syncStatus = .authRequired
            folder.lastErrorMessage = message
            folder.updatedAt = Date()
            try syncRepository.upsertSyncFolder(folder)
        }
        self.lastErrorMessage = message
        self.syncState = .authRequired(message)
        reloadStateFromDatabase()
    }

    /// §10.4 アカウント連携解除：
    /// 1. Keychain 内のトークン削除
    /// 2. 同期設定・カーソル・ジョブ削除
    /// 3. 対象アカウントに紐づく Google ドキュメントの検索データ (`documents`, `document_chunks`, `search_units`, `embeddings`) 削除
    /// 4. アプリ内議事録や他ソースのローカル文書は一切削除しない
    public func disconnectAccount(accountId: String) throws {
        try tokenStore.deleteTokens(forAccountId: accountId)

        let extDocs = try syncRepository.fetchExternalDocuments(accountId: accountId)
        for extDoc in extDocs {
            try documentRepository.deleteDocumentAndAllSearchArtifacts(documentId: extDoc.documentId)
        }

        try syncRepository.deleteAccountData(accountId: accountId)
        reloadStateFromDatabase()
    }

    // MARK: - §3 同期対象フォルダの設定・一覧取得・解除

    /// Google Drive 上のフォルダ一覧を取得する（階層移動・フォルダ名検索・共有ドライブ対応 §3.1, §3.2）
    @discardableResult
    public func refreshAvailableRemoteFolders(
        accountId: String,
        parentFolderId: String? = nil,
        searchQuery: String = ""
    ) async throws -> [GoogleDriveFileItem] {
        _ = try await ensureValidToken(forAccountId: accountId)
        var allFolders: [GoogleDriveFileItem] = []
        var pageToken: String? = nil
        repeat {
            let page = try await executeWithRetry(accountId: accountId) {
                try await self.apiClient.listAvailableFolders(
                    accountId: accountId,
                    parentFolderId: parentFolderId,
                    searchQuery: searchQuery,
                    pageToken: pageToken,
                    pageSize: 100
                )
            }
            allFolders.append(contentsOf: page.files)
            pageToken = page.nextPageToken
        } while pageToken != nil

        self.availableRemoteFolders = allFolders
        return allFolders
    }

    /// §3.1 同期対象フォルダを追加し、初回同期（または手動同期）を行えるようにする
    @discardableResult
    public func addSyncFolder(
        accountId: String,
        folderId: String,
        folderName: String? = nil,
        folderPath: String? = nil,
        driveType: GoogleDriveLocationType? = nil,
        driveId: String? = nil,
        includeSubfolders: Bool = true,
        performInitialSyncImmediately: Bool = true
    ) async throws -> GoogleSyncFolderRecord {
        _ = try await ensureValidToken(forAccountId: accountId)
        let remoteMeta = try await executeWithRetry(accountId: accountId) {
            try await self.apiClient.validateFolderMetadata(accountId: accountId, folderId: folderId)
        }

        let resolvedName = folderName ?? remoteMeta.name
        let resolvedDriveType = driveType ?? remoteMeta.locationType
        let resolvedDriveId = driveId ?? remoteMeta.driveId
        let resolvedPath = folderPath ?? "/\(resolvedName)"
        let now = Date()

        let existing = try syncRepository.fetchSyncFolders(accountId: accountId)
            .first(where: { $0.folderId == folderId })

        let record = GoogleSyncFolderRecord(
            id: existing?.id ?? "\(accountId)::folder::\(folderId)",
            accountId: accountId,
            folderId: folderId,
            folderName: resolvedName,
            folderPath: resolvedPath,
            driveType: resolvedDriveType,
            driveId: resolvedDriveId,
            includeSubfolders: includeSubfolders,
            syncEnabled: true,
            syncStatus: .idle,
            lastSyncedAt: existing?.lastSyncedAt,
            lastFullScanAt: existing?.lastFullScanAt,
            lastErrorMessage: nil,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        try syncRepository.upsertSyncFolder(record)
        reloadStateFromDatabase()

        if performInitialSyncImmediately {
            try await performInitialSync(forSyncFolderId: record.id)
        }
        return (try? syncRepository.fetchSyncFolders(accountId: accountId).first(where: { $0.id == record.id })) ?? record
    }

    /// §10.2 同期フォルダ解除時の扱い：
    /// 別の同期フォルダにも属している文書は残し、どの同期フォルダにも属さなくなった文書のみ検索インデックスから削除する
    public func removeSyncFolder(syncFolderId: String) throws {
        guard let folder = try syncRepository.fetchSyncFolders().first(where: { $0.id == syncFolderId }) else {
            return
        }
        let accountId = folder.accountId
        let affectedMemberships = try syncRepository.fetchMemberships(
            accountId: accountId,
            syncFolderId: syncFolderId,
            onlyActive: false
        )

        // この同期フォルダの所属レコードとフォルダツリーを削除
        try syncRepository.deleteMemberships(accountId: accountId, syncFolderId: syncFolderId)
        try syncRepository.deleteFolderTreeForSyncFolder(accountId: accountId, rootSyncFolderId: syncFolderId)
        try syncRepository.deleteSyncFolder(id: syncFolderId)

        // 各文書が他の有効な同期フォルダにまだ所属しているか確認 (§5.5, §10.2)
        for membership in affectedMemberships {
            try purgeExternalDocumentIfOrphaned(
                accountId: accountId,
                externalFileId: membership.externalFileId
            )
        }
        reloadStateFromDatabase()
    }

    // MARK: - §4 初回同期（12ステップ + 初回探索中の変更追従）

    /// §4.1 初回同期フロー：
    /// 1. OAuth トークン確認
    /// 2. フォルダ探索開始前に `changes.getStartPageToken` を取得して `google_sync_cursors` に保存（初回同期中の変更取りこぼし防止）
    /// 3. 対象フォルダ存在・権限確認
    /// 4. サブフォルダ再帰探索 (`visitedFolderIds` による循環防止・途中失敗時は不完全一覧として扱い誤削除しない §3.3, §4.2)
    /// 5. `files.list` 全ページ取得 (`application/vnd.google-apps.document` のみ対象、ショートカット・他形式は除外 §3.4, §3.5)
    /// 6. 本文取得 (`files.export(text/markdown)` 第一候補、サイズ上限時は Docs API `documents.get(includeTabsContent=true)` フォールバック §4.4, §4.5)
    /// 7〜9. 最大同時取得数 (`maxConcurrentDocumentFetches`) 制限下で正規化・`ImportableDocument` 経由で段階的に検索インデックスへ登録
    /// 10〜11. `external_documents`, `google_document_memberships`, 同期完了日時を保存
    /// 12. 初回探索開始前に取得した `startPageToken` を使って `performIncrementalSync` を実行し、初回同期中に発生した変更を反映
    public func performInitialSync(forSyncFolderId syncFolderId: String) async throws {
        guard var folder = try syncRepository.fetchSyncFolders().first(where: { $0.id == syncFolderId }) else {
            return
        }
        let accountId = folder.accountId
        _ = try await ensureValidToken(forAccountId: accountId)

        isExecutingSync = true
        defer {
            isExecutingSync = false
            reloadStateFromDatabase()
        }

        folder.syncStatus = .syncing
        folder.lastErrorMessage = nil
        folder.updatedAt = Date()
        try syncRepository.upsertSyncFolder(folder)
        syncState = .syncing
        syncProgress = GoogleDriveSyncProgress(
            phaseDescription: "「\(folder.folderName)」のフォルダ階層を走査中...",
            processedDocuments: 0,
            totalDocuments: 0,
            currentDocumentTitle: nil
        )

        do {
            // Step 2: フォルダ探索を開始する「前」に Changes API の開始トークンを取得・保存 (§4.1 #2)
            if try syncRepository.fetchSyncCursor(accountId: accountId) == nil {
                let startToken = try await executeWithRetry(accountId: accountId) {
                    try await self.apiClient.getStartPageToken(accountId: accountId, driveId: folder.driveId)
                }
                try syncRepository.upsertSyncCursor(GoogleSyncCursorRecord(
                    accountId: accountId,
                    scopeKey: "default",
                    pageToken: startToken,
                    updatedAt: Date()
                ))
            }

            // Step 3〜5: フォルダツリー再帰走査と Google ドキュメント全ページ取得
            let scanOutcome = try await scanSyncFolderTreeAndCollectDocuments(folder: folder)

            // Step 6〜10: 収集した Google ドキュメントを並列数制限付きで取得・インデックス化 (§9.1)
            try await fetchAndIndexCollectedDocuments(
                accountId: accountId,
                syncFolder: folder,
                documentsWithFolder: scanOutcome.documents,
                pruneMissingMemberships: scanOutcome.isCompleteListing
            )

            let now = Date()
            folder.syncStatus = .idle
            folder.lastSyncedAt = now
            folder.lastFullScanAt = now
            folder.lastErrorMessage = nil
            folder.updatedAt = now
            try syncRepository.upsertSyncFolder(folder)
            self.lastSyncedAt = now
            self.syncProgress = nil
            self.syncState = .idle

            // Step 12: 初回同期中に発生した変更を、探索開始前に保存した `startPageToken` から Changes API で追従反映 (§4.1 #12)
            try await performIncrementalSync(accountId: accountId)
        } catch let apiError as GoogleDriveAPIError {
            try handleSyncError(apiError, accountId: accountId, folderId: folder.id)
            throw apiError
        } catch {
            folder.syncStatus = .error
            folder.lastErrorMessage = error.localizedDescription
            folder.updatedAt = Date()
            try? syncRepository.upsertSyncFolder(folder)
            self.lastErrorMessage = error.localizedDescription
            self.syncState = .error(error.localizedDescription)
            throw error
        }
    }

    // MARK: - §3.3, §4.2, §4.3 フォルダツリー再帰探索と `files.list` ページネーション

    private struct FolderScanOutcome {
        let visitedFolderIds: Set<String>
        let documents: [(file: GoogleDriveFileItem, parentFolderId: String)]
        let isCompleteListing: Bool
    }

    private func scanSyncFolderTreeAndCollectDocuments(folder: GoogleSyncFolderRecord) async throws -> FolderScanOutcome {
        let accountId = folder.accountId
        // Step 3: ルート対象フォルダのメタデータ検証
        let rootMeta = try await executeWithRetry(accountId: accountId) {
            try await self.apiClient.validateFolderMetadata(accountId: accountId, folderId: folder.folderId)
        }

        // §3.3 訪問済みフォルダIDセットで循環・重複探索を防止
        var visitedFolderIds = Set<String>()
        var queue: [(folderId: String, parentId: String?, folderName: String)] = [
            (rootMeta.id, rootMeta.parents.first, rootMeta.name)
        ]
        var collectedTreeNodes: [GoogleFolderTreeNodeRecord] = []
        var collectedDocs: [(file: GoogleDriveFileItem, parentFolderId: String)] = []

        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard !visitedFolderIds.contains(current.folderId) else {
                continue
            }
            visitedFolderIds.insert(current.folderId)

            collectedTreeNodes.append(GoogleFolderTreeNodeRecord(
                accountId: accountId,
                folderId: current.folderId,
                parentFolderId: current.parentId,
                rootSyncFolderId: folder.id,
                folderName: current.folderName,
                trashed: false,
                updatedAt: Date()
            ))

            // `files.list` の全ページ取得 (§4.2: 途中で失敗した場合は例外を送出し、既存データを誤削除しない)
            var pageToken: String? = nil
            repeat {
                let page = try await executeWithRetry(accountId: accountId) {
                    try await self.apiClient.listChildrenInFolder(
                        accountId: accountId,
                        folderId: current.folderId,
                        driveId: folder.driveId,
                        pageToken: pageToken,
                        pageSize: 100
                    )
                }

                for item in page.files where !item.trashed {
                    // §3.5 ショートカット (`application/vnd.google-apps.shortcut`) は追跡しない
                    if item.isShortcut {
                        continue
                    }
                    if item.isFolder {
                        if folder.includeSubfolders && !visitedFolderIds.contains(item.id) {
                            queue.append((item.id, current.folderId, item.name))
                        }
                    } else if item.isGoogleDocument {
                        // §3.4 `application/vnd.google-apps.document` のみ対象
                        collectedDocs.append((item, current.folderId))
                    }
                }

                pageToken = page.nextPageToken
            } while pageToken != nil
        }

        // 全ページの探索が正常に完了した場合のみ、`google_folder_tree` を更新 (§4.2)
        try syncRepository.deleteFolderTreeForSyncFolder(accountId: accountId, rootSyncFolderId: folder.id)
        for node in collectedTreeNodes {
            try syncRepository.upsertFolderTreeNode(node)
        }

        return FolderScanOutcome(
            visitedFolderIds: visitedFolderIds,
            documents: collectedDocs,
            isCompleteListing: true
        )
    }

    // MARK: - §4.4〜§4.6, §9.1 本文取得・Markdown/Docs APIフォールバック・段階的インデックス登録

    private func fetchAndIndexCollectedDocuments(
        accountId: String,
        syncFolder: GoogleSyncFolderRecord,
        documentsWithFolder: [(file: GoogleDriveFileItem, parentFolderId: String)],
        pruneMissingMemberships: Bool
    ) async throws {
        let total = documentsWithFolder.count
        var processed = 0
        var activeFileIdsInThisScan = Set<String>()

        // §9.1 最大同時取得数を制限（初期値 3）してバッチ処理
        let batchSize = max(1, configuration.maxConcurrentDocumentFetches)
        var index = 0

        while index < documentsWithFolder.count {
            let end = min(index + batchSize, documentsWithFolder.count)
            let slice = Array(documentsWithFolder[index..<end])

            for entry in slice {
                let item = entry.file
                let parentFolderId = entry.parentFolderId
                activeFileIdsInThisScan.insert(item.id)

                syncProgress = GoogleDriveSyncProgress(
                    phaseDescription: "Googleドキュメントをインデックス化中 (\(processed + 1)/\(total))",
                    processedDocuments: processed,
                    totalDocuments: total,
                    currentDocumentTitle: item.name
                )

                try await syncSingleGoogleDocumentItem(
                    accountId: accountId,
                    item: item,
                    parentFolderId: parentFolderId,
                    belongingSyncFolderIds: [syncFolder.id]
                )

                processed += 1
                syncProgress = GoogleDriveSyncProgress(
                    phaseDescription: "Googleドキュメントをインデックス化中 (\(processed)/\(total))",
                    processedDocuments: processed,
                    totalDocuments: total,
                    currentDocumentTitle: item.name
                )
            }
            index = end
        }

        // §4.2 完全な一覧取得に成功した場合のみ、この同期フォルダから外れた古い membership を 정리
        if pruneMissingMemberships {
            let existingMemberships = try syncRepository.fetchMemberships(
                accountId: accountId,
                syncFolderId: syncFolder.id,
                onlyActive: false
            )
            for m in existingMemberships where !activeFileIdsInThisScan.contains(m.externalFileId) {
                try syncRepository.deleteMemberships(
                    accountId: accountId,
                    externalFileId: m.externalFileId,
                    syncFolderId: syncFolder.id
                )
                try purgeExternalDocumentIfOrphaned(
                    accountId: accountId,
                    externalFileId: m.externalFileId
                )
            }
        }
    }

    /// 単一の Google ドキュメントを取得・差分判定し、インデックスおよび所属情報を更新する (§4.4〜§4.6, §5.4, §5.5, §11.3)
    private func syncSingleGoogleDocumentItem(
        accountId: String,
        item: GoogleDriveFileItem,
        parentFolderId: String?,
        belongingSyncFolderIds: [String]
    ) async throws {
        guard item.isGoogleDocument, !item.trashed else { return }

        let now = Date()
        let documentId = Self.canonicalDocumentId(accountId: accountId, externalFileId: item.id)
        let existingExternal = try syncRepository.fetchExternalDocument(accountId: accountId, externalFileId: item.id)
        let existingIndexedDoc = try documentRepository.fetchDocument(id: documentId)

        // 1. 所属フォルダ情報 (`google_document_memberships`) を更新 (§5.5)
        for syncFolderId in belongingSyncFolderIds {
            try syncRepository.upsertMembership(GoogleDocumentMembershipRecord(
                accountId: accountId,
                externalFileId: item.id,
                syncFolderId: syncFolderId,
                folderId: parentFolderId ?? item.parents.first ?? "",
                isActive: true,
                updatedAt: now
            ))
        }

        // 2. §5.4 変更判定 1: `modifiedTime` が前回同期時と同じで、既にインデックスが `.ready` の場合は本文取得を省略
        if let existingExternal,
           let existingIndexedDoc,
           existingIndexedDoc.indexStatus == .ready,
           existingExternal.remoteModifiedTime == item.modifiedTime,
           !failingIndexingExternalFileIdsForTesting.contains(item.id) {
            // タイトルだけ変わったケースがあればタイトルのみ高速更新 (§5.4)
            if existingIndexedDoc.title != item.name {
                try indexManager.updateDocumentTitleOnly(
                    documentId: documentId,
                    newTitle: item.name,
                    modifiedAt: Self.parseISO8601(item.modifiedTime) ?? now,
                    embeddingAdapter: embeddingAdapterProvider()
                )
            }
            // 親フォルダ移動の反映
            if existingExternal.parentFolderId != (parentFolderId ?? item.parents.first) {
                var updatedExt = existingExternal
                updatedExt.parentFolderId = parentFolderId ?? item.parents.first
                updatedExt.lastSyncedAt = now
                try syncRepository.upsertExternalDocument(updatedExt)
            }
            return
        }

        // 3. 本文取得 (§4.4 第一候補: `files.export(mimeType=text/markdown)`、上限超過時等は §4.5 `documents.get(includeTabsContent=true)` へフォールバック)
        let normalizedContent = try await fetchNormalizedGoogleDocumentContent(
            accountId: accountId,
            fileId: item.id
        )
        let newContentHash = SemanticDocumentChunker.sha256Hex(of: normalizedContent)

        // 4. §5.4 変更判定 2 & 3: 本文の `content_hash` が同一で既に `.ready` なら、チャンク分割や Embedding 再生成をスキップ
        if let existingExternal,
           let existingIndexedDoc,
           existingIndexedDoc.indexStatus == .ready,
           existingExternal.contentHash == newContentHash,
           !failingIndexingExternalFileIdsForTesting.contains(item.id) {
            if existingIndexedDoc.title != item.name {
                // タイトルのみ変更時はタイトル検索用インデックスのみ更新 (§5.4)
                try indexManager.updateDocumentTitleOnly(
                    documentId: documentId,
                    newTitle: item.name,
                    modifiedAt: Self.parseISO8601(item.modifiedTime) ?? now,
                    embeddingAdapter: embeddingAdapterProvider()
                )
            }
            var updatedExt = existingExternal
            updatedExt.parentFolderId = parentFolderId ?? item.parents.first
            updatedExt.remoteModifiedTime = item.modifiedTime
            updatedExt.remoteVersion = item.version
            updatedExt.webViewLink = item.webViewLink
            updatedExt.syncStatus = .synced
            updatedExt.lastSyncedAt = now
            updatedExt.lastErrorMessage = nil
            try syncRepository.upsertExternalDocument(updatedExt)
            return
        }

        // 5. `ImportableDocument` を構築し、既存検索基盤の `IndexManager` でインデックス生成 (§7.1, §11.3)
        let modifiedDate = Self.parseISO8601(item.modifiedTime) ?? now
        let createdDate = item.createdTime.flatMap(Self.parseISO8601) ?? modifiedDate
        let importable = ImportableDocument(
            externalId: item.id,
            sourceType: .googleDrive,
            title: item.name,
            content: normalizedContent,
            sourceURI: item.webViewLink,
            createdAt: createdDate,
            updatedAt: modifiedDate,
            metadata: [
                "parentFolderId": parentFolderId ?? item.parents.first ?? "",
                "accountId": accountId
            ]
        )

        let simulateFailure = failingIndexingExternalFileIdsForTesting.contains(item.id)
        do {
            _ = try indexManager.indexImportableDocument(
                importable,
                documentId: documentId,
                embeddingAdapter: embeddingAdapterProvider(),
                forceReindex: false,
                simulateFailureForTesting: simulateFailure
            )

            let extRecord = ExternalDocumentRecord(
                id: existingExternal?.id ?? "\(accountId)::ext::\(item.id)",
                documentId: documentId,
                provider: "google_drive",
                accountId: accountId,
                externalFileId: item.id,
                parentFolderId: parentFolderId ?? item.parents.first,
                mimeType: item.mimeType,
                webViewLink: item.webViewLink,
                remoteModifiedTime: item.modifiedTime,
                remoteVersion: item.version,
                contentHash: newContentHash,
                syncStatus: .synced,
                lastSyncedAt: now,
                lastErrorMessage: nil
            )
            try syncRepository.upsertExternalDocument(extRecord)
        } catch {
            // §11.3 インデックス生成失敗時は既存の正常なインデックスを維持したまま、`external_documents` にエラーステータスを記録
            let errExt = ExternalDocumentRecord(
                id: existingExternal?.id ?? "\(accountId)::ext::\(item.id)",
                documentId: documentId,
                provider: "google_drive",
                accountId: accountId,
                externalFileId: item.id,
                parentFolderId: parentFolderId ?? item.parents.first,
                mimeType: item.mimeType,
                webViewLink: item.webViewLink,
                remoteModifiedTime: existingExternal?.remoteModifiedTime ?? item.modifiedTime,
                remoteVersion: existingExternal?.remoteVersion ?? item.version,
                contentHash: existingExternal?.contentHash ?? "",
                syncStatus: .error,
                lastSyncedAt: existingExternal?.lastSyncedAt,
                lastErrorMessage: error.localizedDescription
            )
            try? syncRepository.upsertExternalDocument(errExt)
            throw error
        }
    }

    /// §4.4 `files.export(mimeType=text/markdown)` を第一候補とし、エクスポートサイズ制限超過時は §4.5 Google Docs API `documents.get(includeTabsContent=true)` へフォールバックする
    private func fetchNormalizedGoogleDocumentContent(accountId: String, fileId: String) async throws -> String {
        do {
            let rawMarkdown = try await executeWithRetry(accountId: accountId) {
                try await self.apiClient.exportDocumentMarkdown(accountId: accountId, fileId: fileId)
            }
            return GoogleDocsContentParser.normalizeExportedMarkdown(rawMarkdown)
        } catch GoogleDriveAPIError.exportSizeLimitExceeded {
            // §4.4, §4.5 エクスポートサイズ上限超過時は Google Docs API `documents.get?includeTabsContent=true` へフォールバック
            let structuredDoc = try await executeWithRetry(accountId: accountId) {
                try await self.apiClient.getStructuredDocument(accountId: accountId, documentId: fileId, includeTabsContent: true)
            }
            return GoogleDocsContentParser.extractNormalizedMarkdown(from: structuredDoc)
        }
    }

    // MARK: - §5 自動差分同期（Changes API + トランザクションジョブキュー + 10種類のイベント処理）

    /// 全連携アカウントに対して差分同期（および必要に応じた定期フルスキャン）を実行する
    public func syncAllConnectedAccounts(triggerReason: String = "manual") async {
        guard !configuration.isPaused else {
            syncState = .paused
            return
        }
        guard !isExecutingSync else { return }

        // 短時間に重複同期が走らないようデバウンス（手動同期以外）
        let now = Date()
        if triggerReason != "manual", now.timeIntervalSince(lastTriggerTimestamp) < 2.0 {
            return
        }
        lastTriggerTimestamp = now

        let activeAccounts = (try? syncRepository.fetchAccounts().filter { $0.status == .connected }) ?? []
        for account in activeAccounts {
            try? await performIncrementalSync(accountId: account.id)
        }
    }

    /// §5.2〜§5.6 指定アカウントの未完了ジョブ再開および Changes API 差分同期を実行する
    public func performIncrementalSync(accountId: String) async throws {
        guard !configuration.isPaused else {
            syncState = .paused
            return
        }
        _ = try await ensureValidToken(forAccountId: accountId)

        isExecutingSync = true
        syncState = .syncing
        defer {
            isExecutingSync = false
            reloadStateFromDatabase()
        }

        // 1. まず前回アプリ終了時などに残っていた未完了 (`pending` / `processing`) ジョブを再開処理 (§5.2, §13.3)
        let interruptedJobs = try syncRepository.fetchSyncJobs(accountId: accountId, statuses: [.pending, .processing])
        if !interruptedJobs.isEmpty {
            try await processPendingSyncJobs(accountId: accountId)
            if maxJobsToProcessBeforeSimulatedInterrupt != nil {
                return
            }
        }

        // 2. カーソル (`pageToken`) の取得。存在しない場合は初回同期を実行
        let folders = try syncRepository.fetchSyncFolders(accountId: accountId).filter(\.syncEnabled)
        guard !folders.isEmpty else { return }

        guard let cursor = try syncRepository.fetchSyncCursor(accountId: accountId) else {
            for folder in folders {
                try await performInitialSync(forSyncFolderId: folder.id)
            }
            return
        }

        // 3. §5.6 定期的な全件再走査判定（最後のフルスキャンから `fullRescanIntervalHours` 経過している場合）
        let now = Date()
        let fullRescanThreshold = TimeInterval(configuration.fullRescanIntervalHours * 3600)
        for folder in folders {
            if let lastFull = folder.lastFullScanAt, now.timeIntervalSince(lastFull) >= fullRescanThreshold {
                try await performInitialSync(forSyncFolderId: folder.id)
            }
        }

        // 4. `changes.list` を全ページ取得 (§5.2)
        var allChanges: [GoogleDriveChangeItem] = []
        var currentToken: String? = cursor.pageToken
        var finalNewStartPageToken: String? = nil
        let primaryDriveId = folders.compactMap(\.driveId).first

        do {
            while let token = currentToken {
                let response = try await executeWithRetry(accountId: accountId) {
                    try await self.apiClient.listChanges(
                        accountId: accountId,
                        pageToken: token,
                        driveId: primaryDriveId,
                        pageSize: 100
                    )
                }
                allChanges.append(contentsOf: response.changes)
                if let next = response.nextPageToken {
                    currentToken = next
                } else {
                    currentToken = nil
                    finalNewStartPageToken = response.newStartPageToken ?? token
                }
            }
        } catch GoogleDriveAPIError.invalidPageToken {
            // §5.6, §11.1 `pageToken` が無効になった場合は安全な全件再走査へフォールバックし、新しい `startPageToken` を取得
            let freshToken = try await executeWithRetry(accountId: accountId) {
                try await self.apiClient.getStartPageToken(accountId: accountId, driveId: primaryDriveId)
            }
            try syncRepository.upsertSyncCursor(GoogleSyncCursorRecord(
                accountId: accountId,
                scopeKey: "default",
                pageToken: freshToken,
                updatedAt: Date()
            ))
            for folder in folders {
                try await performInitialSync(forSyncFolderId: folder.id)
            }
            return
        } catch let apiError as GoogleDriveAPIError {
            try handleSyncError(apiError, accountId: accountId, folderId: nil)
            throw apiError
        }

        // 5. §5.2 全ページの取得完了後、`google_sync_jobs` の登録と `google_sync_cursors` (`newStartPageToken`) の更新を同一トランザクションで保存
        if let newStartPageToken = finalNewStartPageToken {
            _ = try syncRepository.enqueueChangeJobsAndAdvanceCursorAtomically(
                accountId: accountId,
                scopeKey: "default",
                changes: allChanges,
                newStartPageToken: newStartPageToken
            )
        }

        // 6. 登録された変更ジョブを順次実行 (§5.3)
        try await processPendingSyncJobs(accountId: accountId)

        // 7. 各同期フォルダの最終同期日時を更新
        let completedAt = Date()
        for var folder in try syncRepository.fetchSyncFolders(accountId: accountId) where folder.syncEnabled {
            folder.syncStatus = .idle
            folder.lastSyncedAt = completedAt
            folder.lastErrorMessage = nil
            folder.updatedAt = completedAt
            try syncRepository.upsertSyncFolder(folder)
        }
        self.lastSyncedAt = completedAt
        self.syncState = .idle
    }

    /// `google_sync_jobs` の未完了ジョブを処理する (§5.2, §5.3, §13.3)
    public func processPendingSyncJobs(accountId: String) async throws {
        let jobs = try syncRepository.fetchSyncJobs(accountId: accountId, statuses: [.pending, .processing])
        guard !jobs.isEmpty else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var processedCount = 0

        for var job in jobs {
            if let limit = maxJobsToProcessBeforeSimulatedInterrupt, processedCount >= limit {
                // §13.3 同期途中のアプリ終了シミュレーション：残りのジョブは `.pending` のまま次回起動時に再開される
                break
            }

            job.status = .processing
            job.updatedAt = Date()
            try syncRepository.upsertSyncJob(job)

            do {
                if let data = job.payloadJSON.data(using: .utf8),
                   let changeItem = try? decoder.decode(GoogleDriveChangeItem.self, from: data) {
                    try await applySingleChangeEvent(accountId: accountId, change: changeItem)
                }
                job.status = .completed
                job.lastErrorMessage = nil
                job.updatedAt = Date()
                try syncRepository.upsertSyncJob(job)
                processedCount += 1
            } catch let apiErr as GoogleDriveAPIError {
                switch apiErr {
                case .notFound, .forbiddenPermission:
                    // §10.1, §13.4 404/403 権限喪失・削除時は即座にローカル検索インデックスから除外してジョブ完了とする
                    try removeExternalFileCompletely(accountId: accountId, externalFileId: job.externalFileId)
                    job.status = .completed
                    job.updatedAt = Date()
                    try syncRepository.upsertSyncJob(job)
                    processedCount += 1
                default:
                    job.status = .failed
                    job.retryCount += 1
                    job.lastErrorMessage = apiErr.localizedDescription
                    job.updatedAt = Date()
                    try syncRepository.upsertSyncJob(job)
                    try handleSyncError(apiErr, accountId: accountId, folderId: nil)
                    throw apiErr
                }
            } catch {
                job.status = .failed
                job.retryCount += 1
                job.lastErrorMessage = error.localizedDescription
                job.updatedAt = Date()
                try syncRepository.upsertSyncJob(job)
                throw error
            }
        }
    }

    /// §5.3 検出する10種類の変更イベントの処理
    private func applySingleChangeEvent(accountId: String, change: GoogleDriveChangeItem) async throws {
        let fileId = change.fileId
        let syncFolders = try syncRepository.fetchSyncFolders(accountId: accountId).filter(\.syncEnabled)
        let folderTreeNodes = try syncRepository.fetchFolderTreeNodes(accountId: accountId)

        // ケース A: 削除またはゴミ箱移動 (`removed == true` or `file.trashed == true`) (§5.3 #6, #10)
        if change.removed || change.file?.trashed == true {
            // サブフォルダの削除かどうかを確認 (§5.3 #10)
            let matchingFolderNodes = folderTreeNodes.filter { $0.folderId == fileId }
            if !matchingFolderNodes.isEmpty || change.file?.isFolder == true {
                try handleSubfolderRemovedOrMovedOut(accountId: accountId, folderId: fileId)
            }
            // ドキュメント自身の削除 (§5.3 #6)
            try removeExternalFileCompletely(accountId: accountId, externalFileId: fileId)
            return
        }

        guard let item = change.file else {
            try removeExternalFileCompletely(accountId: accountId, externalFileId: fileId)
            return
        }

        // §3.5 ショートカットは対象外
        if item.isShortcut {
            return
        }

        // ケース B: フォルダの追加・移動 (§5.3 #8, #9, #10)
        if item.isFolder {
            try await handleFolderChangeEvent(
                accountId: accountId,
                folderItem: item,
                syncFolders: syncFolders,
                existingTreeNodes: folderTreeNodes
            )
            return
        }

        // ケース C: Google ドキュメント以外のファイルはスキップ (§3.4)
        guard item.isGoogleDocument else {
            return
        }

        // 現在の親フォルダがどの `sync_folder_id` の配下に属しているかを判定
        let matchingSyncFolderIds = resolveMatchingSyncFolderIds(
            parentFolderIds: item.parents,
            syncFolders: syncFolders,
            folderTreeNodes: folderTreeNodes
        )

        if matchingSyncFolderIds.isEmpty {
            // §5.3 #5 対象フォルダ外への移動：すべての対象フォルダ所属を解除し、所属が0になればインデックス削除
            try syncRepository.deleteMemberships(accountId: accountId, externalFileId: item.id)
            try purgeExternalDocumentIfOrphaned(accountId: accountId, externalFileId: item.id)
        } else {
            // 以前所属していたが今回外れた syncFolderId があれば解除
            let previousMemberships = try syncRepository.fetchMemberships(
                accountId: accountId,
                externalFileId: item.id,
                onlyActive: false
            )
            let newSet = Set(matchingSyncFolderIds)
            for prev in previousMemberships where !newSet.contains(prev.syncFolderId) {
                try syncRepository.deleteMemberships(
                    accountId: accountId,
                    externalFileId: item.id,
                    syncFolderId: prev.syncFolderId
                )
            }

            // §5.3 #1, #2, #3, #4 新規追加・本文更新・タイトル変更・対象フォルダ内移動
            try await syncSingleGoogleDocumentItem(
                accountId: accountId,
                item: item,
                parentFolderId: item.parents.first,
                belongingSyncFolderIds: matchingSyncFolderIds
            )
        }
    }

    /// §5.3 #8, #9, #10 サブフォルダの追加・対象フォルダ内への移動・対象フォルダ外への移動
    private func handleFolderChangeEvent(
        accountId: String,
        folderItem: GoogleDriveFileItem,
        syncFolders: [GoogleSyncFolderRecord],
        existingTreeNodes: [GoogleFolderTreeNodeRecord]
    ) async throws {
        // サブフォルダの親がどの同期フォルダ配下にいるか判定（サブフォルダ同期有効な syncFolder のみ）
        let eligibleSyncFolders = syncFolders.filter(\.includeSubfolders)
        let matchingRootSyncFolderIds = resolveMatchingSyncFolderIds(
            parentFolderIds: folderItem.parents,
            syncFolders: eligibleSyncFolders,
            folderTreeNodes: existingTreeNodes
        )

        if matchingRootSyncFolderIds.isEmpty {
            // §5.3 #10 サブフォルダが対象フォルダ外へ移動された場合
            let wasTracked = existingTreeNodes.contains { $0.folderId == folderItem.id }
            if wasTracked {
                try handleSubfolderRemovedOrMovedOut(accountId: accountId, folderId: folderItem.id)
            }
            return
        }

        // §5.3 #8, #9 サブフォルダが対象フォルダ配下に追加・移動された場合、そのサブツリーを再帰走査して配下の文書をインデックス化
        for rootSyncFolderId in matchingRootSyncFolderIds {
            guard let rootSyncFolder = syncFolders.first(where: { $0.id == rootSyncFolderId }) else { continue }
            var visited = Set<String>()
            var queue: [(folderId: String, parentId: String?, name: String)] = [
                (folderItem.id, folderItem.parents.first, folderItem.name)
            ]
            var discoveredDocs: [(file: GoogleDriveFileItem, parentFolderId: String)] = []

            while !queue.isEmpty {
                let current = queue.removeFirst()
                guard !visited.contains(current.folderId) else { continue }
                visited.insert(current.folderId)

                try syncRepository.upsertFolderTreeNode(GoogleFolderTreeNodeRecord(
                    accountId: accountId,
                    folderId: current.folderId,
                    parentFolderId: current.parentId,
                    rootSyncFolderId: rootSyncFolderId,
                    folderName: current.name,
                    trashed: false,
                    updatedAt: Date()
                ))

                var pageToken: String? = nil
                repeat {
                    let page = try await executeWithRetry(accountId: accountId) {
                        try await self.apiClient.listChildrenInFolder(
                            accountId: accountId,
                            folderId: current.folderId,
                            driveId: rootSyncFolder.driveId,
                            pageToken: pageToken,
                            pageSize: 100
                        )
                    }
                    for child in page.files where !child.trashed && !child.isShortcut {
                        if child.isFolder {
                            queue.append((child.id, current.folderId, child.name))
                        } else if child.isGoogleDocument {
                            discoveredDocs.append((child, current.folderId))
                        }
                    }
                    pageToken = page.nextPageToken
                } while pageToken != nil
            }

            try await fetchAndIndexCollectedDocuments(
                accountId: accountId,
                syncFolder: rootSyncFolder,
                documentsWithFolder: discoveredDocs,
                pruneMissingMemberships: false
            )
        }
    }

    /// §5.3 #10 サブフォルダが対象フォルダ外へ移動または削除された場合、そのサブツリー配下の所属を解除し、孤立した文書を削除する
    private func handleSubfolderRemovedOrMovedOut(accountId: String, folderId: String) throws {
        let allNodes = try syncRepository.fetchFolderTreeNodes(accountId: accountId)
        var removedFolderIds: Set<String> = [folderId]
        var addedNew = true
        while addedNew {
            addedNew = false
            for node in allNodes {
                if let pId = node.parentFolderId, removedFolderIds.contains(pId), !removedFolderIds.contains(node.folderId) {
                    removedFolderIds.insert(node.folderId)
                    addedNew = true
                }
            }
        }

        try syncRepository.deleteFolderTreeSubtree(accountId: accountId, folderIds: removedFolderIds)

        // 削除されたサブツリー内のフォルダに紐づいていた membership を削除し、他に所属がない文書をパージ
        let allMemberships = try syncRepository.fetchMemberships(accountId: accountId, onlyActive: false)
        var affectedFileIds = Set<String>()
        for m in allMemberships where removedFolderIds.contains(m.folderId) {
            try syncRepository.deleteMemberships(
                accountId: accountId,
                externalFileId: m.externalFileId,
                syncFolderId: m.syncFolderId
            )
            affectedFileIds.insert(m.externalFileId)
        }

        for fileId in affectedFileIds {
            try purgeExternalDocumentIfOrphaned(accountId: accountId, externalFileId: fileId)
        }
    }

    private func resolveMatchingSyncFolderIds(
        parentFolderIds: [String],
        syncFolders: [GoogleSyncFolderRecord],
        folderTreeNodes: [GoogleFolderTreeNodeRecord]
    ) -> [String] {
        guard !parentFolderIds.isEmpty else { return [] }
        let parentSet = Set(parentFolderIds)
        var matchedSyncFolderIds = Set<String>()

        for syncFolder in syncFolders where syncFolder.syncEnabled {
            if parentSet.contains(syncFolder.folderId) {
                matchedSyncFolderIds.insert(syncFolder.id)
                continue
            }
            if syncFolder.includeSubfolders {
                let nodesForRoot = folderTreeNodes.filter {
                    $0.rootSyncFolderId == syncFolder.id && !$0.trashed
                }
                if nodesForRoot.contains(where: { parentSet.contains($0.folderId) }) {
                    matchedSyncFolderIds.insert(syncFolder.id)
                }
            }
        }
        return Array(matchedSyncFolderIds).sorted()
    }

    /// §5.5, §10.2 文書がどの有効な同期フォルダにも属さなくなった場合のみ、検索インデックスと `external_documents` を削除する
    private func purgeExternalDocumentIfOrphaned(accountId: String, externalFileId: String) throws {
        let remaining = try syncRepository.fetchMemberships(
            accountId: accountId,
            externalFileId: externalFileId,
            onlyActive: true
        )
        guard remaining.isEmpty else { return }
        try removeExternalFileCompletely(accountId: accountId, externalFileId: externalFileId)
    }

    private func removeExternalFileCompletely(accountId: String, externalFileId: String) throws {
        let docId = Self.canonicalDocumentId(accountId: accountId, externalFileId: externalFileId)
        try syncRepository.deleteMemberships(accountId: accountId, externalFileId: externalFileId)
        try syncRepository.deleteExternalDocument(accountId: accountId, externalFileId: externalFileId)
        try documentRepository.deleteDocumentAndAllSearchArtifacts(documentId: docId)
    }

    // MARK: - §11 エラー処理・指数バックオフ再試行

    private func executeWithRetry<T: Sendable>(
        accountId: String,
        operation: () async throws -> T
    ) async throws -> T {
        var attempt = 0
        let maxAttempts = max(1, configuration.maxRetryAttempts)

        while true {
            do {
                return try await operation()
            } catch let apiError as GoogleDriveAPIError {
                attempt += 1
                switch apiError {
                case .unauthorized(let msg), .invalidGrant(let msg):
                    // §11.1 401 / invalid_grant は `auth_required` に遷移し再認証を促す
                    try? markAccountAuthRequired(accountId: accountId, message: msg)
                    throw apiError
                case .rateLimited, .serverError:
                    // §11.1 429 / 5xx は指数バックオフで再試行
                    if attempt >= maxAttempts {
                        throw apiError
                    }
                    let delayMs = configuration.initialBackoffMilliseconds * UInt64(1 << (attempt - 1))
                    try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                case .networkOffline:
                    self.syncState = .offline
                    throw apiError
                default:
                    throw apiError
                }
            }
        }
    }

    private func handleSyncError(_ apiError: GoogleDriveAPIError, accountId: String, folderId: String?) throws {
        switch apiError {
        case .unauthorized(let msg), .invalidGrant(let msg):
            try markAccountAuthRequired(accountId: accountId, message: msg)
        case .networkOffline(let msg):
            self.lastErrorMessage = msg
            self.syncState = .offline
        default:
            let msg = apiError.localizedDescription
            self.lastErrorMessage = msg
            self.syncState = .error(msg)
            if let folderId,
               var folder = try syncRepository.fetchSyncFolders(accountId: accountId).first(where: { $0.id == folderId }) {
                folder.syncStatus = .error
                folder.lastErrorMessage = msg
                folder.updatedAt = Date()
                try syncRepository.upsertSyncFolder(folder)
            }
        }
    }

    // MARK: - §5.1, §8.2, §8.3 同期タイミング管理（定期タイマー・スリープ復帰・ネットワーク復帰・一時停止）

    public func setSyncPaused(_ paused: Bool) {
        configuration.isPaused = paused
        if paused {
            periodicSyncTimer?.invalidate()
            periodicSyncTimer = nil
            syncState = .paused
        } else {
            syncState = .idle
            reschedulePeriodicSyncTimer()
        }
    }

    public func updateSyncIntervalMinutes(_ minutes: Int) {
        configuration = GoogleDriveSyncConfiguration(
            syncIntervalMinutes: minutes,
            maxConcurrentDocumentFetches: configuration.maxConcurrentDocumentFetches,
            maxRetryAttempts: configuration.maxRetryAttempts,
            initialBackoffMilliseconds: configuration.initialBackoffMilliseconds,
            fullRescanIntervalHours: configuration.fullRescanIntervalHours,
            isPaused: configuration.isPaused
        )
        reschedulePeriodicSyncTimer()
    }

    public func reschedulePeriodicSyncTimer() {
        periodicSyncTimer?.invalidate()
        guard !configuration.isPaused else { return }
        let intervalSeconds = TimeInterval(max(1, configuration.syncIntervalMinutes) * 60)
        periodicSyncTimer = Timer.scheduledTimer(withTimeInterval: intervalSeconds, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.syncAllConnectedAccounts(triggerReason: "periodic_timer")
            }
        }
    }

    private func setupSystemEventMonitors() {
        // §5.1 macOS スリープ復帰後の自動差分同期
        sleepWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.syncAllConnectedAccounts(triggerReason: "wake_from_sleep")
            }
        }

        // §5.1 ネットワーク再接続後の自動差分同期
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.syncState == .offline {
                    self.syncState = .idle
                }
                await self.syncAllConnectedAccounts(triggerReason: "network_reconnected")
            }
        }
        monitor.start(queue: pathMonitorQueue)
        self.pathMonitor = monitor
    }

    // MARK: - §7.4 原本への遷移（ブラウザで `webViewLink` を開く）

    @discardableResult
    public func openGoogleDocumentInBrowser(documentId: String, openWithNSWorkspace: Bool = true) -> URL? {
        if let doc = try? documentRepository.fetchDocument(id: documentId),
           doc.sourceType == .googleDrive,
           !doc.sourceURI.isEmpty,
           let url = URL(string: doc.sourceURI) {
            if openWithNSWorkspace {
                NSWorkspace.shared.open(url)
            }
            return url
        }
        if let ext = externalDocuments.first(where: { $0.documentId == documentId }),
           let url = URL(string: ext.webViewLink) {
            if openWithNSWorkspace {
                NSWorkspace.shared.open(url)
            }
            return url
        }
        return nil
    }

    // MARK: - Helpers

    /// §2.4 `account_id + external_file_id` の一意なローカル検索ドキュメントID
    public nonisolated static func canonicalDocumentId(accountId: String, externalFileId: String) -> String {
        "gdrive::\(accountId)::\(externalFileId)"
    }

    private nonisolated static func parseISO8601(_ str: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: str) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: str)
    }
}
