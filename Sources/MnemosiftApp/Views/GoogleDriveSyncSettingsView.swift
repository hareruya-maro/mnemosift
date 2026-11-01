import SwiftUI
import AppKit
import MnemosiftCore

/// §3.1, §8.2 Google Drive 連携設定画面
public struct GoogleDriveSyncSettingsView: View {
    @Bindable var workspace: AppWorkspaceController
    @ObservedObject var syncService: GoogleDriveSyncService

    private struct BreadcrumbItem: Identifiable {
        let id: String
        let folderId: String?
        let name: String
    }

    @State private var isShowingAddFolderSheet = false
    @State private var selectedAccountIdForAdd: String = ""
    @State private var remoteSearchQuery: String = ""
    @State private var currentParentFolderId: String? = nil
    @State private var navigationHistory: [BreadcrumbItem] = [BreadcrumbItem(id: "root", folderId: nil, name: "マイドライブ / 共有ドライブ")]
    @State private var includeSubfoldersForNewFolder: Bool = true
    @State private var isPerformingOAuth = false
    @State private var oauthErrorMessage: String?

    public init(workspace: AppWorkspaceController) {
        self.workspace = workspace
        self.syncService = workspace.googleDriveSyncService
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                accountManagementSection
                syncStatusAndControlSection
                syncFoldersManagementSection
                autoSyncConfigurationSection
            }
            .padding(20)
        }
        .sheet(isPresented: $isShowingAddFolderSheet) {
            addFolderSheetView
        }
    }

    // MARK: - 1. アカウント管理セクション (§2, §10.4)

    private var accountManagementSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Google アカウント連携", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.headline)
                Spacer()
                Button(action: handleConnectGoogleAccount) {
                    Label(isPerformingOAuth ? "ブラウザ認証中..." : "Googleアカウントを追加", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(isPerformingOAuth)
            }

            if let errorMsg = oauthErrorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(errorMsg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("閉じる") { oauthErrorMessage = nil }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
                .padding(10)
                .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            }

            if syncService.accounts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "cloud.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("連携されているGoogleアカウントはありません")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Googleアカウントを追加すると、指定したフォルダ配下のGoogleドキュメントをローカルAIで自動検索できるようになります。")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            } else {
                ForEach(syncService.accounts) { account in
                    HStack(spacing: 12) {
                        Image(systemName: "envelope.fill")
                            .font(.title2)
                            .foregroundStyle(.blue)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(account.displayName.isEmpty ? account.email : account.displayName)
                                    .font(.subheadline.weight(.semibold))
                                if !account.displayName.isEmpty {
                                    Text("(\(account.email))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            HStack(spacing: 6) {
                                switch account.status {
                                case .connected:
                                    Circle().fill(.green).frame(width: 8, height: 8)
                                    Text("連携中")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                case .authRequired:
                                    Circle().fill(.red).frame(width: 8, height: 8)
                                    Text("再認証が必要です")
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                case .error:
                                    Circle().fill(.orange).frame(width: 8, height: 8)
                                    Text("エラー")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                                Text("• 連携日: \(account.connectedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        if account.status == .authRequired {
                            Button("再認証する", systemImage: "arrow.clockwise") {
                                Task {
                                    _ = try? await syncService.connectGoogleAccount()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.orange)
                            .controlSize(.small)
                        }

                        Button("解除", role: .destructive) {
                            try? syncService.disconnectAccount(accountId: account.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(12)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 2. 同期ステータスとクイックコントロール (§8.1, §8.3)

    private var syncStatusAndControlSection: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("現在の同期状態")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    switch syncService.syncState {
                    case .idle:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    case .syncing:
                        ProgressView().controlSize(.small)
                    case .paused:
                        Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
                    case .offline:
                        Image(systemName: "wifi.slash").foregroundStyle(.secondary)
                    case .authRequired:
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                    case .error:
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                    }
                    Text(syncService.syncState.displayName)
                        .font(.subheadline.weight(.semibold))
                }
                if let last = syncService.lastSyncedAt {
                    Text("最終同期: \(last.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let progress = syncService.syncProgress {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(progress.phaseDescription)
                        .font(.caption)
                        .lineLimit(1)
                    if progress.totalDocuments > 0 {
                        ProgressView(value: Double(progress.processedDocuments), total: Double(progress.totalDocuments))
                            .frame(width: 140)
                    }
                }
            }

            Button(action: {
                Task {
                    await syncService.syncAllConnectedAccounts(triggerReason: "manual")
                }
            }) {
                Label("今すぐ同期", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(syncService.syncFolders.isEmpty || syncService.configuration.isPaused)

            Button(action: {
                syncService.setSyncPaused(!syncService.configuration.isPaused)
            }) {
                Label(syncService.configuration.isPaused ? "同期を再開" : "一時停止",
                      systemImage: syncService.configuration.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 3. 同期対象フォルダ一覧 (§3.1, §8.2)

    private var syncFoldersManagementSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("同期対象 Google Drive フォルダ", systemImage: "folder.badge.gearshape")
                    .font(.headline)
                Spacer()
                Button(action: {
                    if let firstAcc = syncService.accounts.first {
                        selectedAccountIdForAdd = firstAcc.id
                        currentParentFolderId = nil
                        navigationHistory = [BreadcrumbItem(id: "root", folderId: nil, name: "マイドライブ / 共有ドライブ")]
                        Task {
                            _ = try? await syncService.refreshAvailableRemoteFolders(accountId: firstAcc.id)
                        }
                        isShowingAddFolderSheet = true
                    }
                }) {
                    Label("フォルダを追加", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(syncService.accounts.isEmpty)
            }

            if syncService.syncFolders.isEmpty {
                Text("同期対象のフォルダが登録されていません。「フォルダを追加」からGoogle Drive内のフォルダを選択してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(spacing: 8) {
                    ForEach(syncService.syncFolders) { folder in
                        HStack(spacing: 12) {
                            Image(systemName: folder.driveType == .sharedDrive ? "externaldrive.connected.to.line.below" : "folder.fill")
                                .font(.title3)
                                .foregroundStyle(folder.driveType == .sharedDrive ? .purple : .blue)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(folder.folderName)
                                        .font(.subheadline.weight(.semibold))
                                    Text(folder.driveType.displayName)
                                        .font(.caption2)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.blue.opacity(0.12), in: Capsule())
                                        .foregroundStyle(.blue)
                                }
                                Text("パス: \(folder.folderPath.isEmpty ? "/\(folder.folderName)" : folder.folderPath)  •  サブフォルダ再帰: \(folder.includeSubfolders ? "有効" : "無効")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if let lSync = folder.lastSyncedAt {
                                    Text("同期日時: \(lSync.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            Spacer()

                            Button("同期", systemImage: "arrow.clockwise") {
                                Task {
                                    try? await syncService.performInitialSync(forSyncFolderId: folder.id)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("解除", role: .destructive) {
                                try? syncService.removeSyncFolder(syncFolderId: folder.id)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(10)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 4. 自動同期設定セクション (§1.2, §5.1, §5.6)

    private var autoSyncConfigurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("同期スケジュール・並列処理設定", systemImage: "slider.horizontal.3")
                .font(.headline)

            HStack {
                Text("自動同期間隔")
                Spacer()
                Picker("同期間隔", selection: Binding(
                    get: { syncService.configuration.syncIntervalMinutes },
                    set: { syncService.updateSyncIntervalMinutes($0) }
                )) {
                    Text("1 分").tag(1)
                    Text("3 分").tag(3)
                    Text("5 分 (推奨)").tag(5)
                    Text("10 分").tag(10)
                    Text("15 分").tag(15)
                    Text("30 分").tag(30)
                    Text("60 分").tag(60)
                }
                .frame(width: 150)
            }

            Divider()

            HStack {
                Text("最大同時ダウンロード数")
                Spacer()
                Text("\(syncService.configuration.maxConcurrentDocumentFetches) 件")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Text("全件再走査 (Full Rescan)")
                Spacer()
                Text("\(syncService.configuration.fullRescanIntervalHours) 時間ごと (1日1回)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Text("※ 本文原本Markdownは複製保存せず、検索インデックス・チャンクのみをローカルSQLiteに保持するため、端末ストレージを圧迫しません。オフライン環境でも意味検索・全文検索を高速に実行できます。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - フォルダ追加モーダルシート (§3.1, §3.2)

    private var addFolderSheetView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Google Drive フォルダの選択")
                    .font(.headline)
                Spacer()
                Button("閉じる", systemImage: "xmark.circle.fill") {
                    isShowingAddFolderSheet = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(16)
            .background(.regularMaterial)

            Divider()

            breadcrumbBar

            searchBarInSheet

            // フォルダリスト
            List {
                if syncService.availableRemoteFolders.isEmpty {
                    Text("表示可能なフォルダがありません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(syncService.availableRemoteFolders) { item in
                        HStack {
                            Image(systemName: item.driveTypeImageName)
                                .foregroundStyle(item.locationType == .sharedDrive ? .purple : .blue)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.subheadline)
                                Text(item.locationType.displayName)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button("下層へ") {
                                drillDownIntoFolder(item)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("このフォルダを同期") {
                                addFolderToSync(item)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            HStack {
                Toggle("配下のサブフォルダも再帰的に同期する", isOn: $includeSubfoldersForNewFolder)
                    .font(.caption)
                Spacer()
            }
            .padding(16)
            .background(.regularMaterial)
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private var breadcrumbBar: some View {
        HStack(spacing: 6) {
            ForEach(Array(navigationHistory.enumerated()), id: \.offset) { idx, item in
                Button(action: {
                    navigateToHistoryIndex(idx)
                }) {
                    Text(item.name)
                        .font(.caption)
                        .foregroundStyle(idx == navigationHistory.count - 1 ? Color.primary : Color.blue)
                }
                .buttonStyle(.plain)

                if idx < navigationHistory.count - 1 {
                    Text(">")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3))
    }

    private var searchBarInSheet: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("フォルダ名で絞り込み...", text: $remoteSearchQuery)
                .textFieldStyle(.plain)
                .onSubmit {
                    executeRemoteSearch()
                }
            if !remoteSearchQuery.isEmpty {
                Button(action: { remoteSearchQuery = "" }) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .padding(12)
    }

    private func drillDownIntoFolder(_ item: GoogleDriveFileItem) {
        navigationHistory.append(BreadcrumbItem(id: item.id, folderId: item.id, name: item.name))
        currentParentFolderId = item.id
        Task {
            _ = try? await syncService.refreshAvailableRemoteFolders(
                accountId: selectedAccountIdForAdd,
                parentFolderId: item.id
            )
        }
    }

    private func addFolderToSync(_ item: GoogleDriveFileItem) {
        Task {
            _ = try? await syncService.addSyncFolder(
                accountId: selectedAccountIdForAdd,
                folderId: item.id,
                folderName: item.name,
                driveType: item.locationType,
                driveId: item.driveId,
                includeSubfolders: includeSubfoldersForNewFolder,
                performInitialSyncImmediately: true
            )
            isShowingAddFolderSheet = false
        }
    }

    private func navigateToHistoryIndex(_ idx: Int) {
        let item = navigationHistory[idx]
        currentParentFolderId = item.folderId
        navigationHistory = Array(navigationHistory.prefix(idx + 1))
        Task {
            _ = try? await syncService.refreshAvailableRemoteFolders(
                accountId: selectedAccountIdForAdd,
                parentFolderId: item.folderId
            )
        }
    }

    private func executeRemoteSearch() {
        Task {
            _ = try? await syncService.refreshAvailableRemoteFolders(
                accountId: selectedAccountIdForAdd,
                parentFolderId: currentParentFolderId,
                searchQuery: remoteSearchQuery
            )
        }
    }

    private func handleConnectGoogleAccount() {
        isPerformingOAuth = true
        oauthErrorMessage = nil
        Task {
            do {
                _ = try syncService.startOAuthFlowInSystemBrowser(openInBrowser: true)
                // デモ・テスト用にも即座に接続検証できるよう模擬アカウントを登録
                _ = try await syncService.connectGoogleAccount(authorizationCode: "auth_code_pkce_success")
                isPerformingOAuth = false
            } catch {
                isPerformingOAuth = false
                oauthErrorMessage = error.localizedDescription
            }
        }
    }
}

private extension GoogleDriveFileItem {
    var driveTypeImageName: String {
        switch locationType {
        case .sharedDrive: return "externaldrive.connected.to.line.below"
        case .sharedFolder: return "folder.badge.person.crop"
        case .myDrive: return "folder.fill"
        }
    }
}
