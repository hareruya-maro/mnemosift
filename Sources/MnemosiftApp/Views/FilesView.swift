import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MnemosiftCore

/// 仕様書 §9.5 & §7: ファイル管理・分類・整理提案画面
/// - ファイル一覧、ドラッグ＆ドロップ、保存方式の選択（元場所参照 vs 管理領域コピー）
/// - 段階的AI分類結果（ルール → 判断モデル → LLM）、タグ、関連プロジェクト、関連ファイル
/// - AIによる整理提案（リネーム・フォルダ移動・タグ付け・プロジェクト関連付け）の「承認して適用」と「元に戻す（ロールバック）」
public struct FilesView: View {
    @Bindable var workspace: AppWorkspaceController

    @State private var selectedStorageMode: DocumentStorageMode = .referencedInPlace
    @State private var newFileTitle: String = "API設計ガイドライン.md"
    @State private var newFileContent: String = """
    # Mnemosift ローカル推論API・インデックス仕様書
    ファイル分類では System One 判断モデルを優先使用し、軽量処理で判断可能な場合は大型LLMを起動しない。
    全文検索には SQLite FTS5 を利用し、EmbeddingGemma 2 によるベクトル検索と組み合わせる。
    """
    @State private var watchedFolderPathInput: String = ""
    @State private var isDropTargeted: Bool = false

    public init(workspace: AppWorkspaceController) {
        self.workspace = workspace
    }

    public var body: some View {
        HSplitView {
            leftFilesAndRegistrationColumn
                .frame(minWidth: 340, maxWidth: 410)

            rightDocumentAndProposalsColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("ファイル管理・分類")
    }

    private var currentDocument: MnemosiftCore.Document? {
        if let id = workspace.selectedDocumentId {
            return workspace.documentService.documents.first { $0.id == id }
        }
        return workspace.documentService.documents.first
    }

    private var leftFilesAndRegistrationColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                fileRegistrationBox
                folderMonitoringBox
                documentsListBox
            }
            .padding(14)
        }
    }

    private var fileRegistrationBox: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ファイル登録・ドラッグ＆ドロップ")
                .font(.headline)

            Picker("保持方式", selection: $selectedStorageMode) {
                ForEach(DocumentStorageMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .font(.caption)

            // ドラッグ＆ドロップ対応エリア
            VStack(spacing: 6) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.title2)
                    .foregroundStyle(isDropTargeted ? .blue : .secondary)
                Text("ここにTXT / MD / 画像(PNG/JPG等・OCR) / フォルダをドロップ")
                    .font(.caption.bold())
                Text("または下のフォーム・フォルダ指定から即座に登録・段階的AI分類を実行")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(
                isDropTargeted ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDroppedProviders(providers)
            }

            Divider()

            TextField("ファイル名（例: spec_audio.md）", text: $newFileTitle)
                .textFieldStyle(.roundedBorder)

            TextEditor(text: $newFileContent)
                .font(.caption)
                .frame(height: 80)
                .padding(4)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))

            Button("ファイルを登録して段階的AI分類を実行", systemImage: "sparkles.rectangle.stack") {
                registerNewDocumentFromForm()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var folderMonitoringBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("フォルダ指定一括読み込み・自動再読み込み")
                    .font(.subheadline.bold())
                Spacer()
                if workspace.documentService.isFolderSyncRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text("対象: テキストファイル＆画像ファイル(Apple Vision OCR) / 優先度低バックグラウンド実行")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button("フォルダを選択して一括読み込み...", systemImage: "folder.fill.badge.plus") {
                let panel = NSOpenPanel()
                panel.title = "一括読み込み・自動監視するフォルダを選択（テキスト・画像OCR対象）"
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let folderURL = panel.url {
                    Task {
                        let summary = await workspace.documentService.importFolderInBackground(
                            path: folderURL.path,
                            projectId: workspace.selectedProjectId
                        )
                        workspace.statusBannerMessage = "📁 \(summary.statusSummaryText)"
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            HStack {
                TextField("監視対象フォルダパスを直接入力", text: $watchedFolderPathInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Button("読込＆監視追加", systemImage: "eye") {
                    let path = watchedFolderPathInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !path.isEmpty else { return }
                    watchedFolderPathInput = ""
                    Task {
                        let summary = await workspace.documentService.importFolderInBackground(
                            path: path,
                            projectId: workspace.selectedProjectId
                        )
                        workspace.statusBannerMessage = "📁 \(summary.statusSummaryText)"
                    }
                }
                .controlSize(.small)
            }

            if let summary = workspace.documentService.lastFolderImportSummary {
                Text("直近結果: \(summary.statusSummaryText)")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }

            if !workspace.documentService.watchedFolderRecords.isEmpty {
                ForEach(workspace.documentService.watchedFolderRecords) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("監視中: \(record.folderPath)")
                                .font(.caption2.bold())
                                .foregroundStyle(.green)
                                .lineLimit(1)
                            Text("読込 \(record.importedDocumentCount)件 (Text \(record.textDocumentCount) / 画像OCR \(record.imageDocumentCount) / 対象外 \(record.skippedUnsupportedCount))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("再同期") {
                            Task {
                                let summary = await workspace.documentService.importFolderInBackground(
                                    path: record.folderPath,
                                    projectId: record.projectId ?? workspace.selectedProjectId,
                                    includeSubdirectories: record.includeSubdirectories
                                )
                                workspace.statusBannerMessage = "📁 \(summary.statusSummaryText)"
                            }
                        }
                        .controlSize(.mini)
                        Button("解除", role: .destructive) {
                            workspace.documentService.stopMonitoringFolder(path: record.folderPath)
                        }
                        .controlSize(.mini)
                    }
                }
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var documentsListBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("登録済みファイル一覧 (\(workspace.documentService.documents.count))")
                .font(.headline)

            ForEach(workspace.documentService.documents) { doc in
                Button {
                    workspace.selectedDocumentId = doc.id
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(doc.fileName)
                                .font(.subheadline.bold())
                            Spacer()
                            Text(doc.category.rawValue)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.18), in: Capsule())
                        }
                        Text(doc.classificationStage)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        currentDocument?.id == doc.id ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var rightDocumentAndProposalsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let doc = currentDocument {
                    documentDetailCard(doc)
                }
                organizationProposalsCard
            }
            .padding(20)
        }
    }

    private func documentDetailCard(_ doc: MnemosiftCore.Document) -> some View {
        let associatedPids = workspace.projectService.projectIds(forDocument: doc.id, approvedOnly: false)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(doc.fileName)
                        .font(.title3.bold())
                    Text("現在のパス: \(doc.filePath) （原本パス: \(doc.originalPath) / \(doc.storageMode.displayName)）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("このファイルから専門用語候補をAI抽出", systemImage: "character.book.closed") {
                    Task {
                        _ = try? await workspace.projectService.extractVocabularyCandidatesWithAI(
                            fromText: doc.extractedText,
                            source: .extractedFromDocument,
                            projectId: workspace.selectedProjectId ?? associatedPids.first
                        )
                        workspace.statusBannerMessage = "『\(doc.fileName)』から専門用語候補を抽出しました（プロジェクト辞書で承認可能）"
                    }
                }
                .controlSize(.small)
            }

            HStack(spacing: 12) {
                Label("カテゴリ: \(doc.category.rawValue)", systemImage: "tag.fill")
                    .font(.caption.bold())
                Label("分類方式: \(doc.classificationStage)", systemImage: "cpu")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }

            HStack(spacing: 6) {
                Text("タグ:")
                    .font(.caption.bold())
                ForEach(doc.tags, id: \.self) { tag in
                    Text("#\(tag)")
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.secondary.opacity(0.15), in: Capsule())
                }
            }

            HStack(spacing: 8) {
                Text("関連プロジェクト（複数関連付け可）:")
                    .font(.caption.bold())
                ForEach(workspace.projectService.projects) { proj in
                    let isLinked = associatedPids.contains(proj.id)
                    Button(proj.name, systemImage: isLinked ? "checkmark.circle.fill" : "plus.circle") {
                        if isLinked {
                            try? workspace.projectService.removeDocumentAssociation(documentId: doc.id, projectId: proj.id)
                        } else {
                            try? workspace.projectService.associateDocument(documentId: doc.id, projectId: proj.id)
                        }
                        let updatedPids = workspace.projectService.projectIds(forDocument: doc.id)
                        try? workspace.embeddingService.updateProjectAssociationsForSource(sourceId: doc.id, projectIds: updatedPids)
                    }
                    .controlSize(.mini)
                    .buttonStyle(.bordered)
                    .tint(isLinked ? .blue : .secondary)
                }
            }

            GroupBox("内容の概要") {
                Text(doc.summary)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }

            GroupBox("抽出テキストプレビュー") {
                Text(doc.extractedText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var organizationProposalsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AIによるファイル整理提案・操作履歴（破壊的操作は必ずユーザー承認後に適用）")
                .font(.headline)

            ForEach(workspace.documentService.operationHistories) { history in
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(history.status.rawValue)
                                .font(.caption2.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(statusColor(history.status).opacity(0.2), in: Capsule())
                                .foregroundStyle(statusColor(history.status))
                            Text(history.reason)
                                .font(.caption.bold())
                        }
                        Text("ファイル名変更提案: 『\(history.previousFileName)』 → 『\(history.proposedFileName)』")
                            .font(.caption)
                        Text("移動先パス提案: \(history.previousFilePath) → \(history.proposedFilePath)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("提案タグ: \(history.proposedTags.joined(separator: ", "))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if history.status == .pendingApproval {
                        HStack(spacing: 6) {
                            Button("承認して適用", systemImage: "checkmark") {
                                try? workspace.documentService.approveAndApplyFileOperation(historyId: history.id)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button("却下", systemImage: "xmark") {
                                try? workspace.documentService.rejectFileOperation(historyId: history.id)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    } else if history.status == .approvedAndApplied {
                        Button("元に戻す（ロールバック）", systemImage: "arrow.uturn.backward") {
                            try? workspace.documentService.undoFileOperation(historyId: history.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(12)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func statusColor(_ status: FileOperationStatus) -> Color {
        switch status {
        case .pendingApproval: .orange
        case .approvedAndApplied: .green
        case .rejected: .secondary
        case .undone: .blue
        }
    }

    private func registerNewDocumentFromForm() {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(newFileTitle)
        try? newFileContent.write(to: tempURL, atomically: true, encoding: .utf8)
        let pids = workspace.selectedProjectId.map { [$0] } ?? []

        Task {
            if let doc = try? await workspace.documentService.registerFile(
                url: tempURL,
                storageMode: selectedStorageMode,
                explicitContent: newFileContent,
                initialProjectIds: pids
            ) {
                workspace.selectedDocumentId = doc.id
            }
        }
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                        let summary = await workspace.documentService.importFolderInBackground(
                            path: url.path,
                            projectId: workspace.selectedProjectId
                        )
                        workspace.statusBannerMessage = "📁 \(summary.statusSummaryText)"
                    } else {
                        let pids = workspace.selectedProjectId.map { [$0] } ?? []
                        if let doc = try? await workspace.documentService.registerFile(
                            url: url,
                            storageMode: selectedStorageMode,
                            initialProjectIds: pids
                        ) {
                            workspace.selectedDocumentId = doc.id
                        }
                    }
                }
            }
        }
        return true
    }
}
