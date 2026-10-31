import SwiftUI
import MnemosiftCore

/// 仕様書 §9.2: ホーム画面
/// - プロジェクト選択を必須にせず、単発の録音・音声取込・ファイル分類・AI検索を即座に開始可能
/// - 最近の作業、実行中の処理、AIモデルの稼働状態・メモリ状況を一目で確認できる
public struct HomeView: View {
    @Bindable var workspace: AppWorkspaceController
    @State private var quickSearchText: String = ""

    public init(workspace: AppWorkspaceController) {
        self.workspace = workspace
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerBanner

                quickActionsGrid

                HStack(alignment: .top, spacing: 20) {
                    recentActivitiesPanel
                    VStack(alignment: .leading, spacing: 20) {
                        activeModelsStatusPanel
                        runningJobsPanel
                    }
                    .frame(width: 380)
                }
            }
            .padding(24)
        }
        .navigationTitle("ホーム")
    }

    private var headerBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Mnemosift ローカルAIワークスペース")
                        .font(.title2.bold())
                    Text("会議も、ファイルも、メモも。すべて自分のPC内でAIが整理する。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("作業プロジェクト（任意）", selection: $workspace.selectedProjectId) {
                    Text("プロジェクト未指定（単発処理）").tag(UUID?.none)
                    ForEach(workspace.projectService.projects) { project in
                        Text(project.name).tag(UUID?.some(project.id))
                    }
                }
                .frame(width: 300)
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("ファイル名・議事録・発言内容をローカルAI検索...", text: $quickSearchText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        performQuickSearch()
                    }
                Button("AI検索へ移動", systemImage: "arrow.right.circle.fill") {
                    performQuickSearch()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(10)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var quickActionsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
            quickActionCard(
                title: "録音開始",
                subtitle: "マイク / システム音声 / 同時録音とリアルタイム文字起こし",
                icon: "waveform.badge.mic",
                tint: .red
            ) {
                workspace.selectedSection = .recording
            }

            quickActionCard(
                title: "音声ファイル取り込み",
                subtitle: "録音済みWAV/M4Aを取り込みSTT・AI補正を実行",
                icon: "waveform.path.ecg.rectangle",
                tint: .blue
            ) {
                workspace.selectedSection = .recording
            }

            quickActionCard(
                title: "ファイル分類・整理",
                subtitle: "TXT / MD / PDF / コードを段階的AI分類・整理提案",
                icon: "folder.fill.badge.gearshape",
                tint: .orange
            ) {
                workspace.selectedSection = .files
            }

            quickActionCard(
                title: "AI検索・RAGチャット",
                subtitle: "FTS5全文検索＋Embedding意味検索＋参照元付き回答",
                icon: "sparkle.magnifyingglass",
                tint: .purple
            ) {
                workspace.selectedSection = .searchChat
            }
        }
    }

    private func quickActionCard(
        title: String,
        subtitle: String,
        icon: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon)
                        .font(.title2)
                        .foregroundStyle(tint)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 115, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var recentActivitiesPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("最近の作業（議事録・文字起こし・ファイル）")
                .font(.headline)

            if workspace.llmService.meetings.isEmpty && workspace.documentService.documents.isEmpty {
                ContentUnavailableView(
                    "まだ作業履歴がありません",
                    systemImage: "tray",
                    description: Text("上のクイックアクションから録音やファイル登録を開始できます。")
                )
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("最近の議事録")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                    ForEach(workspace.llmService.meetings.prefix(3)) { meeting in
                        Button {
                            workspace.selectedMeetingId = meeting.id
                            workspace.selectedSection = .meetings
                        } label: {
                            HStack {
                                Image(systemName: "doc.text.fill")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(meeting.title)
                                        .font(.subheadline.bold())
                                    Text(meeting.overview)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text("決定\(meeting.decisions.count) / TODO \(meeting.actionItems.count)")
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(.blue.opacity(0.12), in: Capsule())
                            }
                            .padding(10)
                            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }

                    Divider()

                    Text("最近登録されたファイル")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                    ForEach(workspace.documentService.documents.prefix(4)) { doc in
                        Button {
                            workspace.selectedDocumentId = doc.id
                            workspace.selectedSection = .files
                        } label: {
                            HStack {
                                Image(systemName: "doc.badge.gearshape")
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(doc.fileName)
                                        .font(.subheadline.bold())
                                    Text("\(doc.category.rawValue) ・ \(doc.classificationStage)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(doc.storageMode == .copiedToManagedStorage ? "管理コピー" : "元場所参照")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var activeModelsStatusPanel: some View {
        let activeProject = workspace.projectService.project(for: workspace.selectedProjectId)
        let resolved = workspace.modelManager.resolveConfiguration(project: activeProject)
        let mem = workspace.jobManager.memorySnapshot

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("AIモデルの稼働状態")
                    .font(.headline)
                Spacer()
                Button("設定変更", systemImage: "slider.horizontal.3") {
                    workspace.selectedSection = .settings
                }
                .controlSize(.small)
            }

            Text("適用スコープ: \(resolved.appliedScopeLabel)")
                .font(.caption)
                .foregroundStyle(.blue)

            VStack(spacing: 8) {
                modelRow(label: "リアルタイムSTT", model: resolved.realtimeSTTModel)
                modelRow(label: "判断モデル (System One)", model: resolved.judgeModel)
                modelRow(label: "LLM (議事録・高度補正)", model: resolved.llmModel)
                modelRow(label: "Embedding (意味検索)", model: resolved.embeddingModel)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Apple Silicon メモリ状況:")
                        .font(.caption.bold())
                    Spacer()
                    Text("空き \(mem.availableMemoryMB) MB / 総計 \(mem.totalPhysicalMemoryMB) MB")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(mem.pressureLevel)
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func modelRow(label: String, model: AIModel) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(model.name)
                    .font(.caption.bold())
            }
            Spacer()
            Text("\(model.requiredMemoryMB) MB")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.secondary.opacity(0.15), in: Capsule())
        }
    }

    private var runningJobsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近の推論ジョブ")
                    .font(.headline)
                Spacer()
                Button("履歴一覧", systemImage: "list.bullet") {
                    workspace.selectedSection = .history
                }
                .controlSize(.small)
            }

            ForEach(workspace.jobManager.jobs.prefix(4)) { job in
                HStack {
                    Circle()
                        .fill(job.status == .completed ? .green : (job.status == .running ? .blue : .orange))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(job.title)
                            .font(.caption.bold())
                            .lineLimit(1)
                        Text("\(job.status.rawValue) ・ \(job.priority.label)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func performQuickSearch() {
        guard !quickSearchText.trimmingCharacters(in: .whitespaces).isEmpty else {
            workspace.selectedSection = .searchChat
            return
        }
        _ = workspace.searchService.search(
            query: quickSearchText,
            scopeMode: workspace.selectedProjectId != nil ? .projectPriority : .global,
            targetProjectId: workspace.selectedProjectId
        )
        workspace.selectedSection = .searchChat
    }
}
