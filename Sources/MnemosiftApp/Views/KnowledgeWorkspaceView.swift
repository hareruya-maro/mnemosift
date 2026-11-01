import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MnemosiftCore

/// 普段の資料探し・ファイル整理・用語辞書・RAG質問回答を1つに統合した「資料検索・整理」画面
public struct KnowledgeWorkspaceView: View {
    @Bindable var workspace: AppWorkspaceController

    public enum KnowledgeCategoryTab: String, CaseIterable, Identifiable {
        case all = "すべて"
        case documents = "📄 資料・ファイル"
        case meetings = "📝 過去の議事録"
        case vocabulary = "📖 専門用語辞書"
        case proposals = "✨ AI整理提案"
        public var id: String { rawValue }
    }

    @State private var searchQuery: String = ""
    @State private var searchScope: SearchScopeMode = .projectPriority
    @State private var selectedCategory: KnowledgeCategoryTab = .all
    @State private var isShowingAddDocumentPopover: Bool = false
    @State private var isShowingFolderImportPopover: Bool = false
    @State private var isShowingAddVocabPopover: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var customFolderPathInput: String = ""
    @State private var includeSubdirectoriesForImport: Bool = true

    // 新規資料追加用
    @State private var newDocTitle: String = "新規設計メモ.md"
    @State private var newDocContent: String = "# 音声処理パイプライン仕様\nQwen3-ASRとSystem One判断モデルを非同期キューで接続する。"
    @State private var newDocStorageMode: DocumentStorageMode = .copiedToManagedStorage

    // 選択中ドキュメントの編集・差分更新用
    @State private var isEditingSelectedDoc: Bool = false
    @State private var editingDocContent: String = ""

    // 新規用語追加用
    @State private var newTermCanonical: String = ""
    @State private var newTermReading: String = ""
    @State private var newTermMisread: String = ""
    @State private var newTermDefinition: String = ""

    // AIチャット質問用
    @State private var ragQuestionInput: String = "標準LLMやSTTモデルについてどう決まりましたか？"

    public init(workspace: AppWorkspaceController) {
        self.workspace = workspace
    }

    public var body: some View {
        VStack(spacing: 0) {
            topSearchAndFilterBar
            Divider()

            HSplitView {
                leftKnowledgeListColumn
                    .frame(minWidth: 320, idealWidth: 420, maxWidth: 520, maxHeight: .infinity)

                rightDetailAndRAGChatColumn
                    .frame(minWidth: 340, idealWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers)
        }
    }

    // MARK: - Top Search & Action Bar

    private var topSearchAndFilterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                // 十分な幅がある場合: 1行で並べる
                HStack(spacing: 10) {
                    searchBarInputField
                    searchScopePickerView
                    searchModePickerView
                    searchExecuteButtonView
                    Spacer(minLength: 4)
                    knowledgeActionButtonsView
                }

                // 狭い場合: 2行に折り返す
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        searchBarInputField
                        searchExecuteButtonView
                        Spacer(minLength: 4)
                        knowledgeActionButtonsView
                    }
                    HStack(spacing: 8) {
                        searchScopePickerView
                        searchModePickerView
                        Spacer()
                    }
                }
            }

            HStack(spacing: 8) {
                ForEach(KnowledgeCategoryTab.allCases) { tab in
                    let isSelected = selectedCategory == tab
                    Button {
                        selectedCategory = tab
                    } label: {
                        HStack(spacing: 4) {
                            Text(tab.rawValue)
                            if tab == .proposals {
                                let count = workspace.documentService.operationHistories.filter { $0.status == .pendingApproval }.count
                                if count > 0 {
                                    Text("\(count)")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.orange, in: Capsule())
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                        .font(.caption.bold())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            isSelected ? Color.blue : Color.secondary.opacity(0.12),
                            in: Capsule()
                        )
                        .foregroundStyle(isSelected ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Text("ファイルを画面へドラッグ＆ドロップして即座にAI分類・インデックス登録可能")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    private var searchBarInputField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("資料・議事録・発言キーワードや自然言語で検索...", text: $searchQuery)
                .textFieldStyle(.plain)
                .frame(minWidth: 120)
                .onSubmit {
                    runHybridSearch()
                }
            if !searchQuery.isEmpty {
                Button("クリア", systemImage: "xmark.circle.fill") {
                    searchQuery = ""
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var searchScopePickerView: some View {
        Picker("範囲", selection: $searchScope) {
            ForEach(SearchScopeMode.allCases) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .controlSize(.small)
        .frame(minWidth: 120, maxWidth: 175)
        .onChange(of: searchScope) {
            if !searchQuery.isEmpty { runHybridSearch() }
        }
    }

    private var searchModePickerView: some View {
        Picker(
            "方式",
            selection: Binding(
                get: { workspace.searchService.selectedHybridMode },
                set: { workspace.searchService.selectedHybridMode = $0 }
            )
        ) {
            ForEach(HybridSearchExecutionMode.allCases) { hMode in
                Text(hMode.displayName).tag(hMode)
            }
        }
        .controlSize(.small)
        .frame(minWidth: 150, maxWidth: 220)
        .onChange(of: workspace.searchService.selectedHybridMode) {
            if !searchQuery.isEmpty { runHybridSearch() }
        }
    }

    private var searchExecuteButtonView: some View {
        Button("検索", systemImage: "sparkle.magnifyingglass") {
            runHybridSearch()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }

    private var knowledgeActionButtonsView: some View {
        HStack(spacing: 6) {
            Button("インデックス再生成", systemImage: "arrow.triangle.2.circlepath") {
                if let count = try? workspace.searchService.regenerateAllSearchIndexes() {
                    workspace.statusBannerMessage = "✅ 2階層ハイブリッド検索インデックスを再生成しました（\(count)件）"
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("📁 フォルダ一括読込", systemImage: "folder.badge.plus") {
                isShowingFolderImportPopover = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .popover(isPresented: $isShowingFolderImportPopover) {
                folderBulkImportPopoverContent
            }

            Button("＋ 資料を追加", systemImage: "doc.badge.plus") {
                isShowingAddDocumentPopover = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .popover(isPresented: $isShowingAddDocumentPopover) {
                addDocumentPopoverContent
            }

            Button("＋ 用語登録", systemImage: "character.book.closed") {
                isShowingAddVocabPopover = true
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .popover(isPresented: $isShowingAddVocabPopover) {
                addVocabularyPopoverContent
            }
        }
    }

    // MARK: - Left Column: Filtered List or Hybrid Search Results

    private var leftKnowledgeListColumn: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                    searchHitListSection
                } else {
                    switch selectedCategory {
                    case .all:
                        documentsListSection
                        meetingsListSection
                        vocabularyListSection
                    case .documents:
                        documentsListSection
                    case .meetings:
                        meetingsListSection
                    case .vocabulary:
                        vocabularyListSection
                    case .proposals:
                        fileOrganizationProposalsSection
                    }
                }
            }
            .padding(14)
        }
    }

    private var searchHitListSection: some View {
        let docHits = workspace.searchService.lastDocumentSearchResults
        let metrics = workspace.searchService.lastStorageAndSpeedMetrics
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("2階層ハイブリッド検索結果 (\(docHits.count)文書)")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(
                    format: "検索: %.1fms (FTS %.1fms / Vec %.1fms / RRF %.1fms)",
                    metrics.lastSearchTiming.totalSearchMs,
                    metrics.lastSearchTiming.ftsSearchMs,
                    metrics.lastSearchTiming.vectorSearchMs,
                    metrics.lastSearchTiming.rrfFusionMs
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            if !docHits.isEmpty {
                ForEach(docHits) { docHit in
                    Button {
                        workspace.jumpToDocumentSearchResult(docHit)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                // §7.3 出典バッジ
                                switch docHit.sourceType {
                                case .googleDrive:
                                    Label("Google ドキュメント", systemImage: "cloud.fill")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.cyan.opacity(0.18), in: Capsule())
                                        .foregroundStyle(.blue)
                                case .external:
                                    Label("ローカルファイル", systemImage: "folder.fill")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.secondary.opacity(0.15), in: Capsule())
                                case .local:
                                    Label(docHit.documentType.displayName, systemImage: "doc.text.fill")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.blue.opacity(0.15), in: Capsule())
                                }

                                Text(docHit.title)
                                    .font(.subheadline.bold())
                                Spacer()
                                Text(String(format: "RRF: %.4f", docHit.rrfScore))
                                    .font(.caption2.bold())
                                    .foregroundStyle(.blue)
                            }

                            Text(docHit.snippet)
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .lineLimit(3)

                            HStack(spacing: 8) {
                                Text("📍 \(docHit.locationHintText)")
                                if let fRank = docHit.ftsRank {
                                    Text("FTS #\(fRank)")
                                }
                                if let vRank = docHit.vectorRank {
                                    Text("Vec #\(vRank)")
                                }
                                if let cos = docHit.cosineSimilarity {
                                    Text(String(format: "Cos %.2f", cos))
                                }
                                Spacer()

                                // §7.4 原本への遷移ボタン
                                if docHit.sourceType == .googleDrive {
                                    Button(action: {
                                        _ = workspace.googleDriveSyncService.openGoogleDocumentInBrowser(documentId: docHit.documentId)
                                    }) {
                                        Label("ブラウザで開く", systemImage: "safari")
                                            .font(.caption2)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.mini)
                                } else if !docHit.matchedKeywords.isEmpty {
                                    Text("KW: \(docHit.matchedKeywords.prefix(4).joined(separator: ", "))")
                                        .lineLimit(1)
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ForEach(workspace.searchService.lastSearchResults) { item in
                    Button {
                        selectSearchResult(item)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(item.chunk.sourceType.rawValue)
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.blue.opacity(0.15), in: Capsule())
                                Text(item.chunk.title)
                                    .font(.subheadline.bold())
                                Spacer()
                                Text(String(format: "関連度 %.0f%%", min(99, item.breakdown.totalScore * 100)))
                                    .font(.caption2.bold())
                                    .foregroundStyle(.blue)
                            }
                            Text(item.chunk.content)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var documentsListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("📄 登録資料・ファイル (\(filteredDocuments.count))")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            ForEach(filteredDocuments) { doc in
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
                                .background(.orange.opacity(0.16), in: Capsule())
                        }
                        Text(doc.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        workspace.selectedDocumentId == doc.id ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var meetingsListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("📝 過去の議事録 (\(filteredMeetings.count))")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            ForEach(filteredMeetings) { meeting in
                Button {
                    workspace.selectedMeetingId = meeting.id
                    workspace.selectedDocumentId = nil
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(meeting.title)
                                .font(.subheadline.bold())
                            Spacer()
                            Text("決定\(meeting.decisions.count) / TODO \(meeting.actionItems.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(meeting.overview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        (workspace.selectedDocumentId == nil && workspace.selectedMeetingId == meeting.id)
                            ? Color.blue.opacity(0.15)
                            : Color.secondary.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var vocabularyListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("📖 専門用語辞書 (\(workspace.projectService.vocabularies.count))")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("議事録から用語候補をAI抽出", systemImage: "sparkles") {
                    let allMinutes = workspace.llmService.meetings.map(\.markdownContent).joined(separator: "\n")
                    Task {
                        _ = try? await workspace.projectService.extractVocabularyCandidatesWithAI(
                            fromText: allMinutes,
                            source: .extractedFromMeeting,
                            projectId: workspace.selectedProjectId
                        )
                    }
                }
                .controlSize(.mini)
            }

            ForEach(workspace.projectService.vocabularies) { vocab in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(vocab.canonicalForm)
                                .font(.subheadline.bold())
                            if !vocab.reading.isEmpty {
                                Text("(\(vocab.reading))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(vocab.approvalStatus.rawValue)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(
                                    vocab.approvalStatus == .approved ? Color.green.opacity(0.2) : Color.orange.opacity(0.2),
                                    in: Capsule()
                                )
                        }
                        Text(vocab.definition)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if vocab.approvalStatus == .candidate {
                        Button("承認") {
                            try? workspace.projectService.approveVocabulary(id: vocab.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.mini)
                    }
                }
                .padding(10)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var fileOrganizationProposalsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("✨ AIによるファイル整理提案（承認後に適用・いつでもロールバック可能）")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            ForEach(workspace.documentService.operationHistories) { history in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(history.status.rawValue)
                            .font(.caption2.bold())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.18), in: Capsule())
                        Text("『\(history.previousFileName)』→『\(history.proposedFileName)』")
                            .font(.caption.bold())
                        Spacer()
                        if history.status == .pendingApproval {
                            Button("承認して適用") {
                                try? workspace.documentService.approveAndApplyFileOperation(historyId: history.id)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.mini)
                        } else if history.status == .approvedAndApplied {
                            Button("元に戻す") {
                                try? workspace.documentService.undoFileOperation(historyId: history.id)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                    Text(history.reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Right Column: Selected Item Preview + RAG AI Chat

    private var rightDetailAndRAGChatColumn: some View {
        VSplitView {
            upperResourceInspectorPane
                .frame(minHeight: 260, idealHeight: 360, maxHeight: .infinity)

            lowerRAGChatAssistantPane
                .frame(minHeight: 230, idealHeight: 300, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var upperResourceInspectorPane: some View {
        if let docId = workspace.selectedDocumentId,
           let doc = workspace.documentService.documents.first(where: { $0.id == docId }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(doc.fileName)
                            .font(.title3.bold())
                        Text("\(doc.category.rawValue) ・ \(doc.classificationStage) ・ パス: \(doc.filePath)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let pending = workspace.documentService.operationHistories.first(where: { $0.documentId == doc.id && $0.status == .pendingApproval }) {
                        Button("リネーム提案『\(pending.proposedFileName)』を承認", systemImage: "checkmark.circle.fill") {
                            try? workspace.documentService.approveAndApplyFileOperation(historyId: pending.id)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .controlSize(.small)
                    } else if let applied = workspace.documentService.operationHistories.first(where: { $0.documentId == doc.id && $0.status == .approvedAndApplied }) {
                        Button("整理前のファイル名へ戻す", systemImage: "arrow.uturn.backward") {
                            try? workspace.documentService.undoFileOperation(historyId: applied.id)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if isEditingSelectedDoc {
                        Button("保存して差分インデックス更新", systemImage: "checkmark.circle.fill") {
                            if let outcome = try? workspace.documentService.updateDocumentContent(
                                documentId: doc.id,
                                newContent: editingDocContent
                            ) {
                                workspace.statusBannerMessage = "✅ 差分インデックス更新完了（チャンク\(outcome.chunkCount)件 / 再利用\(outcome.reusedVectorCount)件 / 新規生成\(outcome.generatedVectorCount)件）"
                            }
                            isEditingSelectedDoc = false
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Button("編集", systemImage: "pencil") {
                            editingDocContent = doc.extractedText
                            isEditingSelectedDoc = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Button("削除", systemImage: "trash", role: .destructive) {
                        try? workspace.documentService.deleteDocument(documentId: doc.id)
                        workspace.selectedDocumentId = workspace.documentService.documents.first?.id
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if let range = workspace.highlightedCharacterRange {
                    Text("📍 検索ヒット位置: 文字オフセット \(range.start)〜\(range.end)")
                        .font(.caption2.bold())
                        .foregroundStyle(.blue)
                }

                Divider()

                if isEditingSelectedDoc {
                    TextEditor(text: $editingDocContent)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if doc.fileType == .image,
                               let nsImage = NSImage(contentsOfFile: doc.filePath) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("🖼️ 元画像プレビュー（Apple Vision OCR テキスト抽出 ＋ EmbeddingGemma 2 マルチモーダル視覚Embedding 併用）")
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                    Image(nsImage: nsImage)
                                        .resizable()
                                        .scaledToFit()
                                        .frame(maxHeight: 200)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .padding(8)
                                .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            }

                            Text(doc.extractedText)
                                .font(.system(.callout, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(16)
        } else if let meetingId = workspace.selectedMeetingId,
                  let meeting = workspace.llmService.meetings.first(where: { $0.id == meetingId }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meeting.title)
                            .font(.title3.bold())
                        Text("決定事項 \(meeting.decisions.count)件 / TODO \(meeting.actionItems.count)件")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("会議パートナー画面で開く", systemImage: "waveform.and.person.filled") {
                        workspace.jumpToTranscript(from: meeting)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Divider()

                ScrollView {
                    Text(meeting.markdownContent)
                        .font(.system(.callout, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .padding(16)
        } else {
            ContentUnavailableView(
                "左の一覧から資料または議事録を選択してください",
                systemImage: "doc.text.magnifyingglass",
                description: Text("選択した資料や議事録の中身をここで確認できます。")
            )
        }
    }

    private var lowerRAGChatAssistantPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("AIに資料・議事録について質問する (ローカルRAG)", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(.purple)
                Spacer()
                if !workspace.searchService.chatMessages.isEmpty {
                    Button("チャット履歴クリア", systemImage: "trash") {
                        workspace.searchService.clearChatHistory()
                    }
                    .controlSize(.mini)
                }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(workspace.searchService.chatMessages) { msg in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(msg.isUser ? "あなた: \(msg.content)" : msg.content)
                                .font(.caption)
                                .fontWeight(msg.isUser ? .bold : .regular)

                            if !msg.citations.isEmpty {
                                HStack(spacing: 6) {
                                    ForEach(msg.citations) { cit in
                                        Button("📎 \(cit.title)") {
                                            if cit.sourceType == .document {
                                                workspace.selectedDocumentId = cit.sourceId
                                            } else if cit.sourceType == .meetingMinutes {
                                                workspace.selectedDocumentId = nil
                                                workspace.selectedMeetingId = cit.sourceId
                                            }
                                        }
                                        .controlSize(.mini)
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            msg.isUser ? Color.purple.opacity(0.10) : Color.secondary.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("過去の決定事項や仕様書の内容を質問...", text: $ragQuestionInput)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit {
                        askRAG()
                    }
                Button("質問する", systemImage: "paperplane.fill") {
                    askRAG()
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .controlSize(.small)
            }
        }
        .padding(16)
        .background(.regularMaterial)
    }

    // MARK: - Popovers & Helpers

    private var addDocumentPopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ローカル資料・メモの登録")
                .font(.headline)
            TextField("ファイル名 (例: spec_v2.md)", text: $newDocTitle)
                .textFieldStyle(.roundedBorder)
            Picker("保存方式", selection: $newDocStorageMode) {
                ForEach(DocumentStorageMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .font(.caption)
            TextEditor(text: $newDocContent)
                .font(.caption)
                .frame(width: 360, height: 120)
                .padding(4)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Spacer()
                Button("登録してAI分類", systemImage: "checkmark.circle.fill") {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(newDocTitle)
                    try? newDocContent.write(to: url, atomically: true, encoding: .utf8)
                    let pids = workspace.selectedProjectId.map { [$0] } ?? []
                    Task {
                        if let doc = try? await workspace.documentService.registerFile(
                            url: url,
                            storageMode: newDocStorageMode,
                            explicitContent: newDocContent,
                            initialProjectIds: pids
                        ) {
                            workspace.selectedDocumentId = doc.id
                            workspace.refreshMeetingPartnerState()
                        }
                    }
                    isShowingAddDocumentPopover = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }

    private var folderBulkImportPopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("フォルダ指定一括読み込み・自動再読み込み監視", systemImage: "folder.badge.gearshape")
                    .font(.headline)
                Spacer()
                if workspace.documentService.isFolderSyncRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text("対象ファイル: テキストファイル (.txt / .md / .csv / .json / コード等) および画像ファイル (.png / .jpg / .heic / .webp等 — Apple Vision OCR テキスト抽出 ＋ EmbeddingGemma 2 マルチモーダル視覚Embedding の両方併用)\n※PDF・Microsoft Office文書は今後のアップデートで順次対応予定（現在は自動スキップ）\n※優先度低（バックグラウンド処理）で実行され、ファイル更新時は自動再読み込み＆差分インデックス更新を行います。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Toggle("サブフォルダ内のファイルも再帰的に読み込む", isOn: $includeSubdirectoriesForImport)
                .font(.caption)

            HStack(spacing: 8) {
                Button("フォルダを選択して一括読み込み...", systemImage: "folder.fill.badge.plus") {
                    selectFolderWithOpenPanel()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                TextField("またはフォルダパスを直接入力", text: $customFolderPathInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)

                Button("パス読込") {
                    let path = customFolderPathInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !path.isEmpty else { return }
                    customFolderPathInput = ""
                    Task {
                        let summary = await workspace.documentService.importFolderInBackground(
                            path: path,
                            projectId: workspace.selectedProjectId,
                            includeSubdirectories: includeSubdirectoriesForImport
                        )
                        workspace.statusBannerMessage = "📁 \(summary.statusSummaryText)"
                        workspace.refreshMeetingPartnerState()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if let summary = workspace.documentService.lastFolderImportSummary {
                Text("直近の同期結果: \(summary.statusSummaryText) (\(String(format: "%.0fms", summary.elapsedMs)))")
                    .font(.caption2.bold())
                    .foregroundStyle(.blue)
            }

            if !workspace.documentService.watchedFolderRecords.isEmpty {
                Divider()
                Text("監視中フォルダ一覧（ファイル更新時に自動再読み込み）")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)

                ForEach(workspace.documentService.watchedFolderRecords) { record in
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.folderPath)
                                .font(.caption.bold())
                                .lineLimit(1)
                            Text("読込済 \(record.importedDocumentCount)件 (Text \(record.textDocumentCount) / 画像OCR \(record.imageDocumentCount) / 対象外スキップ \(record.skippedUnsupportedCount)) ・ \(record.lastSyncStatusMessage)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("再スキャン", systemImage: "arrow.clockwise") {
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
                        .buttonStyle(.bordered)

                        Button("解除", role: .destructive) {
                            workspace.documentService.stopMonitoringFolder(path: record.folderPath)
                        }
                        .controlSize(.mini)
                        .buttonStyle(.bordered)
                    }
                    .padding(6)
                    .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .padding(16)
        .frame(width: 540)
    }

    private func selectFolderWithOpenPanel() {
        let panel = NSOpenPanel()
        panel.title = "一括読み込み・自動監視するフォルダを選択（テキスト・画像OCR対象）"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let folderURL = panel.url {
            let includeSub = includeSubdirectoriesForImport
            Task {
                let summary = await workspace.documentService.importFolderInBackground(
                    path: folderURL.path,
                    projectId: workspace.selectedProjectId,
                    includeSubdirectories: includeSub
                )
                workspace.statusBannerMessage = "📁 \(summary.statusSummaryText)"
                workspace.refreshMeetingPartnerState()
            }
        }
    }

    private var addVocabularyPopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("専門用語の手動登録")
                .font(.headline)
            TextField("正式表記 (例: WhisperKit)", text: $newTermCanonical)
                .textFieldStyle(.roundedBorder)
            TextField("読み方 (例: ウィスパーキット)", text: $newTermReading)
                .textFieldStyle(.roundedBorder)
            TextField("よくある誤認識 (カンマ区切り)", text: $newTermMisread)
                .textFieldStyle(.roundedBorder)
            TextField("用語の解説", text: $newTermDefinition)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("辞書に追加") {
                    guard !newTermCanonical.isEmpty else { return }
                    let misreads = newTermMisread
                        .components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    _ = try? workspace.projectService.addVocabularyManually(
                        projectId: workspace.selectedProjectId,
                        canonicalForm: newTermCanonical,
                        reading: newTermReading,
                        aliases: [],
                        commonMisrecognitions: misreads,
                        definition: newTermDefinition
                    )
                    newTermCanonical = ""
                    newTermReading = ""
                    newTermMisread = ""
                    newTermDefinition = ""
                    isShowingAddVocabPopover = false
                    workspace.refreshMeetingPartnerState()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private var filteredDocuments: [MnemosiftCore.Document] {
        guard let pid = workspace.selectedProjectId, searchScope == .projectExclusive else {
            return workspace.documentService.documents
        }
        return workspace.documentService.documents.filter {
            workspace.projectService.projectIds(forDocument: $0.id, approvedOnly: false).contains(pid)
        }
    }

    private var filteredMeetings: [Meeting] {
        guard let pid = workspace.selectedProjectId, searchScope == .projectExclusive else {
            return workspace.llmService.meetings
        }
        return workspace.llmService.meetings.filter { $0.projectIds.contains(pid) }
    }

    private func runHybridSearch() {
        _ = workspace.searchService.search(
            query: searchQuery,
            scopeMode: searchScope,
            targetProjectId: workspace.selectedProjectId
        )
    }

    private func selectSearchResult(_ item: SearchResultItem) {
        switch item.chunk.sourceType {
        case .document:
            workspace.selectedDocumentId = item.chunk.sourceId
        case .meetingMinutes:
            workspace.selectedDocumentId = nil
            workspace.selectedMeetingId = item.chunk.sourceId
        case .transcriptSegment:
            workspace.activeTranscriptId = item.chunk.sourceId
            workspace.activeMode = .meetingPartner
        }
    }

    private func askRAG() {
        let q = ragQuestionInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        Task {
            _ = try? await workspace.searchService.askQuestion(
                question: q,
                scopeMode: searchScope,
                targetProjectId: workspace.selectedProjectId
            )
        }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                        let summary = await workspace.documentService.importFolderInBackground(
                            path: url.path,
                            projectId: workspace.selectedProjectId,
                            includeSubdirectories: includeSubdirectoriesForImport
                        )
                        workspace.statusBannerMessage = "📁 \(summary.statusSummaryText)"
                        workspace.refreshMeetingPartnerState()
                    } else {
                        let pids = workspace.selectedProjectId.map { [$0] } ?? []
                        if let doc = try? await workspace.documentService.registerFile(
                            url: url,
                            storageMode: .referencedInPlace,
                            initialProjectIds: pids
                        ) {
                            workspace.selectedDocumentId = doc.id
                            workspace.refreshMeetingPartnerState()
                        }
                    }
                }
            }
        }
        return true
    }
}
