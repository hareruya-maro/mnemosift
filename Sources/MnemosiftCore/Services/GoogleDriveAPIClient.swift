import Foundation
import AppKit
import CryptoKit
import Security

// MARK: - §2 Google OAuth 2.0 PKCE & Keychain トークン管理

/// §2.3 Keychain に保存する OAuth トークンバンドル（ログ出力時にトークン文字列が漏洩しないよう CustomStringConvertible をマスク）
public struct GoogleOAuthTokenBundle: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var scope: String

    public init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date = Date().addingTimeInterval(3600),
        scope: String = GoogleDriveConstants.readOnlyScope
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }

    public var isExpired: Bool {
        Date().addingTimeInterval(60) >= expiresAt
    }

    public var description: String {
        "GoogleOAuthTokenBundle(accessToken: <REDACTED>, refreshToken: <REDACTED>, expiresAt: \(expiresAt), scope: \(scope))"
    }

    public var debugDescription: String {
        description
    }
}

/// §2.1 PKCE (RFC 7636) Code Verifier / Code Challenge 生成器（Client Secret に依存しないデスクトップOAuth保護）
public struct PKCECodeChallengeGenerator: Sendable {
    public let codeVerifier: String
    public let codeChallenge: String
    public let codeChallengeMethod: String = "S256"

    public init(explicitVerifier: String? = nil) {
        if let explicitVerifier, explicitVerifier.count >= 43 {
            self.codeVerifier = explicitVerifier
        } else {
            var randomBytes = [UInt8](repeating: 0, count: 48)
            _ = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
            self.codeVerifier = Self.base64URLEncode(Data(randomBytes))
        }
        let digest = SHA256.hash(data: Data(self.codeVerifier.utf8))
        self.codeChallenge = Self.base64URLEncode(Data(digest))
    }

    /// §2.1, §2.2 システムブラウザで開く Google OAuth 2.0 認可 URL を構築（スコープは `drive.readonly` のみ）
    public func buildAuthorizationURL(
        clientId: String,
        redirectURI: String = "http://127.0.0.1:53682/oauth2redirect",
        state: String = UUID().uuidString
    ) -> URL? {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: GoogleDriveConstants.readOnlyScope),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: codeChallengeMethod),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "state", value: state)
        ]
        return components?.url
    }

    public static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// §2.3 トークン保管インターフェース（SQLite には平文保存せず Keychain で管理）
public protocol GoogleOAuthTokenStore: Sendable {
    func saveTokens(_ tokens: GoogleOAuthTokenBundle, forAccountId accountId: String) throws
    func loadTokens(forAccountId accountId: String) throws -> GoogleOAuthTokenBundle?
    func deleteTokens(forAccountId accountId: String) throws
}

/// §2.3 macOS Keychain (`Security` フレームワーク) による安全なトークン保存実装
public final class MacOSKeychainTokenStore: GoogleOAuthTokenStore, @unchecked Sendable {
    private let serviceName: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(serviceName: String = "com.mnemosift.google-drive-oauth") {
        self.serviceName = serviceName
    }

    public func saveTokens(_ tokens: GoogleOAuthTokenBundle, forAccountId accountId: String) throws {
        let data = try encoder.encode(tokens)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountId
        ]
        SecItemDelete(query as CFDictionary)

        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw GoogleDriveAPIError.unauthorized("Keychain save failed (OSStatus \(status))")
        }
    }

    public func loadTokens(forAccountId accountId: String) throws -> GoogleOAuthTokenBundle? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountId,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return try? decoder.decode(GoogleOAuthTokenBundle.self, from: data)
    }

    public func deleteTokens(forAccountId accountId: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountId
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GoogleDriveAPIError.unauthorized("Keychain delete failed (OSStatus \(status))")
        }
    }
}

/// テスト環境およびサンドボックス環境向けのメモリ内セキュアKeychainストア（SQLiteには一切保存しない）
public final class InMemoryKeychainTokenStore: GoogleOAuthTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: GoogleOAuthTokenBundle] = [:]

    public init() {}

    public func saveTokens(_ tokens: GoogleOAuthTokenBundle, forAccountId accountId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[accountId] = tokens
    }

    public func loadTokens(forAccountId accountId: String) throws -> GoogleOAuthTokenBundle? {
        lock.lock()
        defer { lock.unlock() }
        return storage[accountId]
    }

    public func deleteTokens(forAccountId accountId: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: accountId)
    }
}

// MARK: - §4.4 & §4.5 Googleドキュメント Markdown・マルチタブ構造パーサー (`GoogleDocsContentParser`)

public struct GoogleDocsContentParser: Sendable {
    public init() {}

    /// §4.4 Drive API `files.export?mimeType=text/markdown` で取得したMarkdownを正規化する
    /// - 見出し階層 (`#`, `##`, `###`)、段落、箇条書き、表のテキスト（ヘッダとセルの意味対応を維持）、リンクテキスト、本文順序を保持
    /// - Markdown記法そのもの（エスケープ記号や装飾記号、埋め込みdata URI等）が検索精度を妨げないように整形
    public static func normalizeExportedMarkdown(_ rawMarkdown: String) -> String {
        let unified = rawMarkdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = unified.components(separatedBy: "\n")
        var outputLines: [String] = []
        var activeTableHeaders: [String] = []
        var insideTable = false

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            // Markdown テーブル行 (`| A | B |`) の構造化変換（§4.4 表の内容を無意味に連結して意味が失われないようにする）
            if trimmed.hasPrefix("|") && trimmed.hasSuffix("|") && trimmed.count > 2 {
                let cells = trimmed
                    .dropFirst()
                    .dropLast()
                    .components(separatedBy: "|")
                    .map { cleanInlineMarkdown($0.trimmingCharacters(in: .whitespaces)) }

                // 区切り行 (`| --- | --- |`) はスキップ
                let isSeparatorRow = cells.allSatisfy { cell in
                    !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
                }
                if isSeparatorRow {
                    insideTable = true
                    continue
                }

                if !insideTable && activeTableHeaders.isEmpty {
                    activeTableHeaders = cells
                    insideTable = true
                    outputLines.append("【表ヘッダ】 " + cells.filter { !$0.isEmpty }.joined(separator: " / "))
                } else {
                    var pairedCells: [String] = []
                    for (idx, cell) in cells.enumerated() where !cell.isEmpty {
                        if idx < activeTableHeaders.count && !activeTableHeaders[idx].isEmpty {
                            pairedCells.append("\(activeTableHeaders[idx]): \(cell)")
                        } else {
                            pairedCells.append(cell)
                        }
                    }
                    if !pairedCells.isEmpty {
                        outputLines.append("- " + pairedCells.joined(separator: " | "))
                    }
                }
                continue
            } else {
                insideTable = false
                activeTableHeaders = []
            }

            if trimmed.isEmpty {
                if outputLines.last != "" {
                    outputLines.append("")
                }
                continue
            }

            // 見出し行 (`# `, `## `, `### `) はチャンク分割の優先境界としてそのまま保持 (§4.4)
            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" })
                let rest = cleanInlineMarkdown(String(trimmed.dropFirst(hashes.count)).trimmingCharacters(in: .whitespaces))
                if !rest.isEmpty {
                    outputLines.append("\(hashes) \(rest)")
                }
                continue
            }

            // 箇条書き・番号付きリストの保持 (§4.4)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                let itemText = cleanInlineMarkdown(String(trimmed.dropFirst(2)))
                outputLines.append("- \(itemText)")
                continue
            }

            outputLines.append(cleanInlineMarkdown(trimmed))
        }

        return outputLines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// §4.5 Google Docs API `documents.get?includeTabsContent=true` の複数タブ階層を再帰的に解析し、
    /// タブ名・タブIDと本文の対応を維持したテキストおよびタブメタデータJSONを生成する
    public static func flattenStructuredDocument(_ doc: GoogleDocsStructuredDocument) -> (text: String, tabsMetadataJSON: String) {
        struct TabMetaEntry: Codable {
            let tabId: String
            let title: String
            let startOffset: Int
            let endOffset: Int
        }

        var sections: [String] = []
        var tabMetaEntries: [TabMetaEntry] = []
        var currentOffset = 0

        func traverseTabs(_ tabs: [GoogleDocTabContent], depth: Int) {
            for tab in tabs {
                let headingPrefix = String(repeating: "#", count: min(4, depth + 1))
                let normalizedBody = normalizeExportedMarkdown(tab.markdownOrStructuredText)
                let sectionText = "\(headingPrefix) [タブ: \(tab.title) (ID: \(tab.tabId))]\n\(normalizedBody)"
                let startOff = currentOffset
                let length = sectionText.count
                let endOff = startOff + length
                tabMetaEntries.append(TabMetaEntry(
                    tabId: tab.tabId,
                    title: tab.title,
                    startOffset: startOff,
                    endOffset: endOff
                ))
                sections.append(sectionText)
                currentOffset = endOff + 2 // "\n\n"
                if !tab.childTabs.isEmpty {
                    traverseTabs(tab.childTabs, depth: depth + 1)
                }
            }
        }

        traverseTabs(doc.tabs, depth: 0)
        let fullText = sections.joined(separator: "\n\n")
        let metaData = (try? JSONEncoder().encode(tabMetaEntries))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return (fullText, metaData)
    }

    public static func extractNormalizedMarkdown(from doc: GoogleDocsStructuredDocument) -> String {
        flattenStructuredDocument(doc).text
    }

    /// リンク記法 `[テキスト](URL)` から表示テキストを抽出し、太字・斜体・エスケープ記号などのMarkdown装飾ノイズを除去する
    private static func cleanInlineMarkdown(_ text: String) -> String {
        var result = text
        // 画像埋め込み `![alt](data:image/...)` の除去・alt抽出
        if let imgRegex = try? NSRegularExpression(pattern: #"!\[([^\]]*)\]\([^\)]+\)"#) {
            let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
            result = imgRegex.stringByReplacingMatches(in: result, range: nsRange, withTemplate: "$1")
        }
        // リンク `[リンクテキスト](https://...)` -> `リンクテキスト` (§4.4 リンクテキストの保持)
        if let linkRegex = try? NSRegularExpression(pattern: #"\[([^\]]+)\]\([^\)]+\)"#) {
            let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
            result = linkRegex.stringByReplacingMatches(in: result, range: nsRange, withTemplate: "$1")
        }
        // Markdown エスケープ・太字記号の除去（ただし C++ などのプログラミング記号は保護）
        result = result
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "\\-", with: "-")
            .replacingOccurrences(of: "\\.", with: ".")
            .replacingOccurrences(of: "\\_", with: "_")
            .replacingOccurrences(of: "\\*", with: "*")
        return result.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - §4.2, §4.3, §4.5, §5.2, §16 #1 Google Drive API 専用クライアント抽象と実装

public protocol GoogleDriveAPIClientProtocol: Sendable {
    /// §2.1 OAuth 2.0 認可コードのトークン交換
    func exchangeAuthorizationCode(
        code: String,
        codeVerifier: String,
        clientId: String,
        redirectURI: String
    ) async throws -> (token: GoogleOAuthTokenBundle, accountId: String, email: String, displayName: String)

    /// §2.3 Refresh Token による Access Token 更新
    func refreshAccessToken(refreshToken: String, clientId: String) async throws -> GoogleOAuthTokenBundle

    /// §5.2 `changes.getStartPageToken`
    func getStartPageToken(accountId: String, driveId: String?) async throws -> String

    /// §5.2 `changes.list`
    func listChanges(accountId: String, pageToken: String, driveId: String?, pageSize: Int) async throws -> GoogleDriveChangeListPage

    /// §4.2 `files.list` (`'<FOLDER_ID>' in parents and trashed = false`)
    func listChildrenInFolder(
        accountId: String,
        folderId: String,
        driveId: String?,
        pageToken: String?,
        pageSize: Int
    ) async throws -> GoogleDriveFileListPage

    /// §3.1 フォルダ選択UI用のフォルダ一覧取得（階層移動・フォルダ名絞り込み対応）
    func listAvailableFolders(
        accountId: String,
        parentFolderId: String?,
        searchQuery: String,
        pageToken: String?,
        pageSize: Int
    ) async throws -> GoogleDriveFileListPage

    /// §4.2, §5.3 単一ファイルまたはフォルダのメタデータ取得・検証 (`files.get`)
    func validateFolderMetadata(accountId: String, folderId: String) async throws -> GoogleDriveFileItem

    /// §4.3 `GET /drive/v3/files/{fileId}/export?mimeType=text/markdown`
    func exportDocumentMarkdown(accountId: String, fileId: String) async throws -> String

    /// §4.5 代替取得方法: `GET https://docs.googleapis.com/v1/documents/{fileId}?includeTabsContent=true`
    func getStructuredDocument(accountId: String, documentId: String, includeTabsContent: Bool) async throws -> GoogleDocsStructuredDocument
}

/// デモ・オフライン検証・単体/結合テスト（100件超ページネーション・Changes API差分・エラー注入・マルチタブDocs APIフォールバック）を完全サポートする Google Drive API クライアント
public final class ControllableGoogleDriveAPIClient: GoogleDriveAPIClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var filesById: [String: GoogleDriveFileItem] = [:]
    private var markdownByFileId: [String: String] = [:]
    private var structuredDocsByFileId: [String: GoogleDocsStructuredDocument] = [:]
    private var exportSizeExceededFileIds: Set<String> = []
    private var changesLog: [GoogleDriveChangeItem] = []
    private var pageCounter: Int = 100
    private var invalidatedPageTokens: Set<String> = []

    /// 障害注入・レート制限シミュレーション用設定
    public var isNetworkOffline: Bool = false
    public var simulatedAuthFailureForAccountIds: Set<String> = []
    public var transientFailureRemainingCountByTargetId: [String: Int] = [:]
    public var transientFailureErrorKind: GoogleDriveAPIError = .rateLimited(retryAfterSeconds: 0.01)
    public var permissionDeniedFileIds: Set<String> = []
    public var failMidFolderListingAfterPage: Int?
    public var defaultPageSize: Int = 50
    public private(set) var totalAPICallCount: Int = 0
    public private(set) var exportCallCountByFileId: [String: Int] = [:]

    public init(seedDemoDriveItems: Bool = true) {
        if seedDemoDriveItems {
            seedDefaultDriveContents()
        }
    }

    public func seedDefaultDriveContents() {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        let rootEngFolder = GoogleDriveFileItem(
            id: "gdrive-folder-eng-root",
            name: "01_プロダクト開発・設計書 (Google Drive)",
            mimeType: GoogleDriveConstants.googleFolderMimeType,
            parents: ["root"],
            modifiedTime: now.addingTimeInterval(-86400 * 3),
            webViewLink: "https://drive.google.com/drive/folders/gdrive-folder-eng-root"
        )
        let subArchFolder = GoogleDriveFileItem(
            id: "gdrive-folder-eng-arch",
            name: "アーキテクチャ・認証基盤",
            mimeType: GoogleDriveConstants.googleFolderMimeType,
            parents: ["gdrive-folder-eng-root"],
            modifiedTime: now.addingTimeInterval(-86400 * 2),
            webViewLink: "https://drive.google.com/drive/folders/gdrive-folder-eng-arch"
        )
        let sharedDriveFolder = GoogleDriveFileItem(
            id: "gdrive-folder-shared-pm",
            name: "02_共有ドライブ・企画ロードマップ",
            mimeType: GoogleDriveConstants.googleFolderMimeType,
            parents: ["shared-drive-01"],
            modifiedTime: now.addingTimeInterval(-86400 * 1),
            webViewLink: "https://drive.google.com/drive/folders/gdrive-folder-shared-pm",
            driveId: "shared-drive-01"
        )

        let doc1 = GoogleDriveFileItem(
            id: "gdoc-auth-passkey-spec",
            name: "Google Drive連携・OAuth2 PKCE認証設計書",
            mimeType: GoogleDriveConstants.googleDocMimeType,
            parents: ["gdrive-folder-eng-arch"],
            modifiedTime: now.addingTimeInterval(-7200),
            webViewLink: "https://docs.google.com/document/d/gdoc-auth-passkey-spec/edit"
        )
        let doc2 = GoogleDriveFileItem(
            id: "gdoc-q3-performance-plan",
            name: "検索エンジン省メモリ・レイテンシ改善計画 (Google Docs)",
            mimeType: GoogleDriveConstants.googleDocMimeType,
            parents: ["gdrive-folder-eng-root"],
            modifiedTime: now.addingTimeInterval(-3600),
            webViewLink: "https://docs.google.com/document/d/gdoc-q3-performance-plan/edit"
        )
        let doc3 = GoogleDriveFileItem(
            id: "gdoc-shared-roadmap",
            name: "2026年Q4 共有ドライブ機能ロードマップ",
            mimeType: GoogleDriveConstants.googleDocMimeType,
            parents: ["gdrive-folder-shared-pm"],
            modifiedTime: now.addingTimeInterval(-1800),
            webViewLink: "https://docs.google.com/document/d/gdoc-shared-roadmap/edit",
            driveId: "shared-drive-01"
        )
        // MVP対象外ファイル（スプレッドシート・ショートカット — §3.4 により自動除外されるべきアイテム）
        let ignoredSheet = GoogleDriveFileItem(
            id: "gsheet-budget-2026",
            name: "2026年度インフラ予算シート",
            mimeType: GoogleDriveConstants.googleSpreadsheetMimeType,
            parents: ["gdrive-folder-eng-root"],
            modifiedTime: now.addingTimeInterval(-3600)
        )
        let ignoredShortcut = GoogleDriveFileItem(
            id: "gshortcut-external-secret",
            name: "外部フォルダ文書へのショートカット",
            mimeType: GoogleDriveConstants.googleShortcutMimeType,
            parents: ["gdrive-folder-eng-root"],
            modifiedTime: now.addingTimeInterval(-3600)
        )

        for item in [rootEngFolder, subArchFolder, sharedDriveFolder, doc1, doc2, doc3, ignoredSheet, ignoredShortcut] {
            filesById[item.id] = item
        }

        markdownByFileId[doc1.id] = """
        # Google Drive連携・OAuth2 PKCE認証設計書

        ## 1. 認証フローとスコープ方針
        macOSデスクトップアプリとして Google OAuth 2.0 PKCE (`S256`) を採用し、システムブラウザで認証を行う。
        スコープは `https://www.googleapis.com/auth/drive.readonly` を使用し、Refresh Token は macOS Keychain に安全に保存する。

        ## 2. セキュリティ要件比較
        | 項目 | 採用方式 | 備考 |
        | --- | --- | --- |
        | トークン保存先 | macOS Keychain | SQLiteへの平文保存は禁止 |
        | 文書送信先 | 完全ローカル処理 | 外部AIサーバーへの送信なし |
        """

        markdownByFileId[doc2.id] = """
        # 検索エンジン省メモリ・レイテンシ改善計画

        ## 1. ハイブリッド検索目標
        SQLite FTS5 と 384次元ローカル Embedding による RRF 統合検索において、検索応答時間を 50ミリ秒 以内に維持する。
        - Changes API による 5分間隔の差分同期を採用する。
        - 変更がないドキュメントは `modifiedTime` と `contentHash` により再ベクトル化をスキップする。
        """

        markdownByFileId[doc3.id] = """
        # 2026年Q4 共有ドライブ機能ロードマップ

        ## 決定事項
        共有ドライブ (`supportsAllDrives=true`) 内の Googleドキュメントも再帰的にインデックス化し、オフライン環境でも議事録と横断検索できるようにすることが決定された。
        """
    }

    // MARK: - テストおよびシミュレーション用の操作メソッド

    public func upsertRemoteItem(
        _ item: GoogleDriveFileItem,
        markdown: String? = nil,
        structuredDoc: GoogleDocsStructuredDocument? = nil,
        simulateExportSizeExceeded: Bool = false,
        recordChange: Bool = true
    ) {
        lock.lock()
        defer { lock.unlock() }
        filesById[item.id] = item
        if let markdown {
            markdownByFileId[item.id] = markdown
        }
        if let structuredDoc {
            structuredDocsByFileId[item.id] = structuredDoc
        }
        if simulateExportSizeExceeded {
            exportSizeExceededFileIds.insert(item.id)
        } else {
            exportSizeExceededFileIds.remove(item.id)
        }
        if recordChange {
            changesLog.append(GoogleDriveChangeItem(
                fileId: item.id,
                removed: item.trashed,
                file: item,
                time: item.modifiedTime,
                driveId: item.driveId
            ))
        }
    }

    public func setStructuredDocForFallback(_ structuredDoc: GoogleDocsStructuredDocument, exceedExportLimit: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        structuredDocsByFileId[structuredDoc.documentId] = structuredDoc
        if exceedExportLimit {
            exportSizeExceededFileIds.insert(structuredDoc.documentId)
        } else {
            exportSizeExceededFileIds.remove(structuredDoc.documentId)
        }
    }

    public func removeRemoteItem(fileId: String, driveId: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        filesById.removeValue(forKey: fileId)
        markdownByFileId.removeValue(forKey: fileId)
        changesLog.append(GoogleDriveChangeItem(
            fileId: fileId,
            removed: true,
            file: nil,
            time: Date(),
            driveId: driveId
        ))
    }

    public func invalidatePageToken(_ token: String) {
        lock.lock()
        defer { lock.unlock() }
        invalidatedPageTokens.insert(token)
    }

    public func exportCount(for fileId: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return exportCallCountByFileId[fileId] ?? 0
    }

    // MARK: - GoogleDriveAPIClientProtocol Implementation

    private func withStateLock<T>(_ block: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try block()
    }

    private func checkCommonPreconditions(accountId: String, targetId: String) throws {
        totalAPICallCount += 1
        if isNetworkOffline {
            throw GoogleDriveAPIError.networkOffline("インターネット接続がオフラインです")
        }
        if simulatedAuthFailureForAccountIds.contains(accountId) {
            throw GoogleDriveAPIError.unauthorized("Refresh Token が失効しています。再認証が必要です。")
        }
        if permissionDeniedFileIds.contains(targetId) {
            throw GoogleDriveAPIError.permissionDenied(fileId: targetId, message: "対象への閲覧権限がありません")
        }
        if let remaining = transientFailureRemainingCountByTargetId[targetId], remaining > 0 {
            transientFailureRemainingCountByTargetId[targetId] = remaining - 1
            throw transientFailureErrorKind
        }
    }

    public func getStartPageToken(accountId: String, driveId: String?) async throws -> String {
        try withStateLock {
            try checkCommonPreconditions(accountId: accountId, targetId: driveId ?? "root")
            return "cursor-\(changesLog.count)"
        }
    }

    public func exchangeAuthorizationCode(
        code: String,
        codeVerifier: String,
        clientId: String,
        redirectURI: String
    ) async throws -> (token: GoogleOAuthTokenBundle, accountId: String, email: String, displayName: String) {
        try withStateLock {
            if isNetworkOffline {
                throw GoogleDriveAPIError.networkOffline("インターネット接続がオフラインです")
            }
            if code == "invalid_code" {
                throw GoogleDriveAPIError.invalidGrant("無効な認可コードです")
            }
            let accId = "google-user-01"
            let token = GoogleOAuthTokenBundle(
                accessToken: "mock_access_token_\(UUID().uuidString)",
                refreshToken: "mock_refresh_token_\(UUID().uuidString)",
                expiresAt: Date().addingTimeInterval(3600),
                scope: GoogleDriveConstants.readOnlyScope
            )
            return (token, accId, "engineer@example.com", "山田 太郎")
        }
    }

    public func refreshAccessToken(refreshToken: String, clientId: String) async throws -> GoogleOAuthTokenBundle {
        try withStateLock {
            if isNetworkOffline {
                throw GoogleDriveAPIError.networkOffline("インターネット接続がオフラインです")
            }
            if refreshToken.contains("revoked") {
                throw GoogleDriveAPIError.invalidGrant("リフレッシュトークンが失効しています")
            }
            return GoogleOAuthTokenBundle(
                accessToken: "mock_refreshed_access_\(UUID().uuidString)",
                refreshToken: refreshToken,
                expiresAt: Date().addingTimeInterval(3600),
                scope: GoogleDriveConstants.readOnlyScope
            )
        }
    }

    public func listChanges(accountId: String, pageToken: String, driveId: String?, pageSize: Int = 100) async throws -> GoogleDriveChangeListPage {
        try withStateLock {
            try checkCommonPreconditions(accountId: accountId, targetId: driveId ?? "changes")

            if invalidatedPageTokens.contains(pageToken) || !pageToken.hasPrefix("cursor-") {
                throw GoogleDriveAPIError.invalidSyncPageToken("Invalid or expired startPageToken: \(pageToken)")
            }

            let parts = pageToken.replacingOccurrences(of: "cursor-", with: "").components(separatedBy: "-p")
            let startIndex = Int(parts.first ?? "0") ?? 0
            let allMatching = Array(changesLog.dropFirst(min(startIndex, changesLog.count))).filter { change in
                guard let driveId, !driveId.isEmpty else { return true }
                return change.driveId == driveId || change.file?.driveId == driveId
            }

            let effectivePageSize = max(1, min(pageSize, defaultPageSize))
            let pageOffset = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
            let sliceStart = min(pageOffset, allMatching.count)
            let sliceEnd = min(sliceStart + effectivePageSize, allMatching.count)
            let pageItems = Array(allMatching[sliceStart..<sliceEnd])

            if sliceEnd < allMatching.count {
                return GoogleDriveChangeListPage(
                    changes: pageItems,
                    nextPageToken: "cursor-\(startIndex)-p\(sliceEnd)",
                    newStartPageToken: nil
                )
            } else {
                return GoogleDriveChangeListPage(
                    changes: pageItems,
                    nextPageToken: nil,
                    newStartPageToken: "cursor-\(changesLog.count)"
                )
            }
        }
    }

    public func listChildrenInFolder(
        accountId: String,
        folderId: String,
        driveId: String?,
        pageToken: String?,
        pageSize: Int
    ) async throws -> GoogleDriveFileListPage {
        try withStateLock {
            try checkCommonPreconditions(accountId: accountId, targetId: folderId)

            let offset = pageToken.flatMap { Int($0.replacingOccurrences(of: "page-", with: "")) } ?? 0
            let pageIndex = offset / max(1, pageSize)
            if let failAfter = failMidFolderListingAfterPage, pageIndex >= failAfter {
                throw GoogleDriveAPIError.serverError(statusCode: 503, message: "Simulated mid-folder pagination failure")
            }

            let matching = filesById.values
                .filter { !$0.trashed && $0.parents.contains(folderId) && !permissionDeniedFileIds.contains($0.id) }
                .sorted { $0.id < $1.id }

            let effectivePageSize = max(1, min(pageSize, defaultPageSize))
            let start = min(offset, matching.count)
            let end = min(start + effectivePageSize, matching.count)
            let slice = Array(matching[start..<end])
            let nextToken = end < matching.count ? "page-\(end)" : nil
            return GoogleDriveFileListPage(files: slice, nextPageToken: nextToken)
        }
    }

    public func listAvailableFolders(
        accountId: String,
        parentFolderId: String?,
        searchQuery: String,
        pageToken: String?,
        pageSize: Int
    ) async throws -> GoogleDriveFileListPage {
        try withStateLock {
            try checkCommonPreconditions(accountId: accountId, targetId: parentFolderId ?? "folders")

            let matching = filesById.values
                .filter { item in
                    guard item.isFolder && !item.trashed else { return false }
                    if let parentFolderId, !parentFolderId.isEmpty {
                        guard item.parents.contains(parentFolderId) else { return false }
                    }
                    if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                        guard item.name.localizedCaseInsensitiveContains(searchQuery.trimmingCharacters(in: .whitespaces)) else {
                            return false
                        }
                    }
                    return true
                }
                .sorted { $0.name < $1.name }

            let offset = pageToken.flatMap { Int($0.replacingOccurrences(of: "page-", with: "")) } ?? 0
            let effectivePageSize = max(1, min(pageSize, defaultPageSize))
            let start = min(offset, matching.count)
            let end = min(start + effectivePageSize, matching.count)
            let slice = Array(matching[start..<end])
            let nextToken = end < matching.count ? "page-\(end)" : nil
            return GoogleDriveFileListPage(files: slice, nextPageToken: nextToken)
        }
    }

    public func validateFolderMetadata(accountId: String, folderId: String) async throws -> GoogleDriveFileItem {
        try withStateLock {
            try checkCommonPreconditions(accountId: accountId, targetId: folderId)
            guard let item = filesById[folderId], !item.trashed else {
                throw GoogleDriveAPIError.notFound(fileId: folderId)
            }
            return item
        }
    }

    public func exportDocumentMarkdown(accountId: String, fileId: String) async throws -> String {
        try withStateLock {
            try checkCommonPreconditions(accountId: accountId, targetId: fileId)
            guard let item = filesById[fileId], !item.trashed else {
                throw GoogleDriveAPIError.notFound(fileId: fileId)
            }
            if exportSizeExceededFileIds.contains(fileId) {
                throw GoogleDriveAPIError.exportSizeLimitExceeded(fileId: fileId)
            }
            exportCallCountByFileId[fileId, default: 0] += 1
            return markdownByFileId[fileId] ?? "# \(item.name)\n"
        }
    }

    public func getStructuredDocument(accountId: String, documentId: String, includeTabsContent: Bool) async throws -> GoogleDocsStructuredDocument {
        try withStateLock {
            try checkCommonPreconditions(accountId: accountId, targetId: documentId)
            if let structured = structuredDocsByFileId[documentId] {
                return structured
            }
            guard let item = filesById[documentId], !item.trashed else {
                throw GoogleDriveAPIError.notFound(fileId: documentId)
            }
            let body = markdownByFileId[documentId] ?? "# \(item.name)"
            return GoogleDocsStructuredDocument(
                documentId: documentId,
                title: item.name,
                tabs: [
                    GoogleDocTabContent(
                        tabId: "t.0",
                        title: "メインタブ",
                        index: 0,
                        markdownOrStructuredText: body
                    )
                ]
            )
        }
    }
}
