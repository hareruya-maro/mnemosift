import SwiftUI
import MnemosiftCore

/// 仕様書 §8 & §9.1: AI検索・RAGチャット画面
/// - 3つの検索範囲モード（全体検索、プロジェクト優先検索、プロジェクト限定検索）の明確な区別
/// - マルチファクター検索ランキング内訳の表示（意味類似度・FTS5キーワード・鮮度・プロジェクト一致・重要度）
/// - AIチャット（RAG回答生成、クリックで該当ファイル・議事録・文字起こしに移動可能な参照元表示）
public struct SearchChatView: View {
    @Bindable var workspace: AppWorkspaceController

    @State private var searchQuery: String = "Qwen3-ASR Gemma 4 決定事項"
    @State private var scopeMode: SearchScopeMode = .projectPriority
    @State private var sourceFilter: KnowledgeSourceType?
    @State private var chatQuestionInput: String = "標準LLMやSTTモデルについてどのような決定事項がありますか？"

    public init(workspace: AppWorkspaceController) {
        self.workspace = workspace
    }

    public var body: some View {
        HSplitView {
            leftHybridSearchColumn
                .frame(minWidth: 420, maxWidth: 540)

            rightRAGChatColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("AI検索・チャット")
        .onAppear {
            if workspace.searchService.lastSearchResults.isEmpty {
                executeSearch()
            }
        }
    }

    // MARK: - Left Column: Hybrid Search & Multi-Factor Ranking

    private var leftHybridSearchColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Text("ハイブリッドAI検索（FTS5全文 + Embedding意味検索）")
                    .font(.headline)

                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("検索キーワードまたは自然言語フレーズ...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .onSubmit {
                            executeSearch()
                        }
                    Button("検索実行", systemImage: "sparkle.magnifyingglass") {
                        executeSearch()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

                Picker("検索範囲モード", selection: $scopeMode) {
                    ForEach(SearchScopeMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(scopeMode.description)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Picker("対象プロジェクト", selection: $workspace.selectedProjectId) {
                        Text("未指定").tag(UUID?.none)
                        ForEach(workspace.projectService.projects) { project in
                            Text(project.name).tag(UUID?.some(project.id))
                        }
                    }

                    Picker("種別フィルタ", selection: $sourceFilter) {
                        Text("すべて").tag(KnowledgeSourceType?.none)
                        ForEach(KnowledgeSourceType.allCases, id: \.self) { kind in
                            Text(kind.rawValue).tag(KnowledgeSourceType?.some(kind))
                        }
                    }
                }
                .font(.caption)
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

            Text("検索結果ランキング (\(workspace.searchService.lastSearchResults.count)件) — 古い資料の不当優先防止減衰適用")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(workspace.searchService.lastSearchResults) { item in
                        searchResultCard(item)
                    }
                }
            }
        }
        .padding(16)
    }

    private func searchResultCard(_ item: SearchResultItem) -> some View {
        let b = item.breakdown
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.chunk.sourceType.rawValue)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.15), in: Capsule())
                Text(item.chunk.title)
                    .font(.subheadline.bold())
                Spacer()
                Text(String(format: "総合スコア: %.2f", b.totalScore))
                    .font(.caption.bold())
                    .foregroundStyle(.blue)
            }

            Text(item.chunk.content)
                .font(.caption)
                .lineLimit(3)

            HStack(spacing: 8) {
                Text(String(format: "意味: %.2f", b.semanticSimilarity))
                Text(String(format: "全文/KW: %.2f", b.keywordMatchScore))
                Text(String(format: "鮮度: %.2f", b.recencyScore))
                Text(String(format: "PJ優先: +%.2f", b.projectAlignmentScore))
                if b.importanceScore > 0 {
                    Text("重要/決定事項")
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("該当箇所を開く", systemImage: "arrow.up.right.square") {
                    let citation = ChatCitation(
                        chunkId: item.chunk.id,
                        sourceType: item.chunk.sourceType,
                        sourceId: item.chunk.sourceId,
                        title: item.chunk.title,
                        snippet: item.chunk.content,
                        locationHint: item.chunk.locationHint,
                        score: b.totalScore
                    )
                    workspace.jumpToSource(citation: citation)
                }
                .controlSize(.mini)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Right Column: RAG AI Chat with Source Citations

    private var rightRAGChatColumn: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ローカルRAG AIチャット")
                        .font(.headline)
                    Text("検索結果の根拠に基づき回答を生成し、参照元へのダイレクトジャンプを提供します（根拠がない場合は推測しません）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("履歴クリア", systemImage: "trash") {
                    workspace.searchService.clearChatHistory()
                }
                .controlSize(.small)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if workspace.searchService.chatMessages.isEmpty {
                        ContentUnavailableView(
                            "質問を入力してAIチャットを開始",
                            systemImage: "bubble.left.and.text.bubble.right",
                            description: Text("ローカルに保存された議事録・文字起こし・ファイル群から根拠を検索して回答します。")
                        )
                    } else {
                        ForEach(workspace.searchService.chatMessages) { msg in
                            chatMessageBubble(msg)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                TextField("会議の決定事項や仕様書について質問...", text: $chatQuestionInput)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        askChatQuestion()
                    }
                Button("AIに質問する", systemImage: "paperplane.fill") {
                    askChatQuestion()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(16)
    }

    private func chatMessageBubble(_ msg: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(
                    msg.isUser ? "あなた" : "Mnemosift AI (\(msg.modelId))",
                    systemImage: msg.isUser ? "person.fill" : "sparkles"
                )
                .font(.caption.bold())
                .foregroundStyle(msg.isUser ? Color.primary : Color.purple)
                Spacer()
                Text(msg.searchScope.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(msg.content)
                .font(.callout)

            if !msg.citations.isEmpty {
                Divider()
                Text("参照元（クリックで該当ファイル・議事録へ移動）:")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)

                ForEach(msg.citations) { citation in
                    Button {
                        workspace.jumpToSource(citation: citation)
                    } label: {
                        HStack {
                            Image(systemName: "link")
                                .foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("[\(citation.sourceType.rawValue)] \(citation.title) — \(citation.locationHint)")
                                    .font(.caption.bold())
                                Text(citation.snippet)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                        }
                        .padding(8)
                        .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(
            msg.isUser ? Color.blue.opacity(0.10) : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private func executeSearch() {
        _ = workspace.searchService.search(
            query: searchQuery,
            scopeMode: scopeMode,
            targetProjectId: workspace.selectedProjectId,
            sourceTypeFilter: sourceFilter
        )
    }

    private func askChatQuestion() {
        let q = chatQuestionInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        Task {
            _ = try? await workspace.searchService.askQuestion(
                question: q,
                scopeMode: scopeMode,
                targetProjectId: workspace.selectedProjectId
            )
        }
    }
}
