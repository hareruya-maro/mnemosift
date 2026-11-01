import SwiftUI
import MnemosiftCore

/// サイドバーを廃止した1ウィンドウ・2モード切替メイン画面
/// - 上部統合バーで「🎙️ 会議パートナー」と「📚 資料検索・整理」をワンクリック切替
/// - プロジェクト文脈スイッチャーと設定・外部連携シートボタンを上部に配置
public struct MainWorkspaceView: View {
    @Bindable var workspace: AppWorkspaceController
    @State private var isShowingNewProjectPopover: Bool = false
    @State private var newProjectName: String = ""
    @State private var newProjectDesc: String = ""

    public init(workspace: AppWorkspaceController) {
        self.workspace = workspace
    }

    public var body: some View {
        VStack(spacing: 0) {
            topUnifiedHeaderBar
            Divider()

            // 資料検索モード閲覧中に録音が行われている場合は、上部にコンパクトな録音ステータスバーを常時表示
            if workspace.activeMode == .knowledgeHub &&
               (workspace.recordingService.state == .recording || workspace.recordingService.state == .paused) {
                RecordingStatusBar(workspace: workspace)
            }

            if let banner = workspace.statusBannerMessage {
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    Text(banner)
                        .font(.callout)
                    Spacer()
                    Button("閉じる", systemImage: "xmark") {
                        workspace.statusBannerMessage = nil
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.blue.opacity(0.1))
            }

            switch workspace.activeMode {
            case .meetingPartner:
                MeetingPartnerView(workspace: workspace)
            case .knowledgeHub:
                KnowledgeWorkspaceView(workspace: workspace)
            }
        }
        .sheet(isPresented: $workspace.isShowingSettingsSheet) {
            SettingsAndToolsSheet(workspace: workspace)
        }
    }

    private var topUnifiedHeaderBar: some View {
        HStack(spacing: 16) {
            // 左側: アプリアイコン・名前 ＋ プロジェクト文脈切替フィルタ
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    if let appIcon = MnemosiftApp.loadAppIconImage() {
                        Image(nsImage: appIcon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 24, height: 24)
                    } else {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                    }
                    Text("Mnemosift")
                        .font(.headline.bold())
                }

                Divider()
                    .frame(height: 18)

                Picker("プロジェクト", selection: $workspace.selectedProjectId) {
                    Text("すべてのプロジェクト（単発）").tag(UUID?.none)
                    ForEach(workspace.projectService.projects) { project in
                        Text("📁 \(project.name)").tag(UUID?.some(project.id))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 220)
                .onChange(of: workspace.selectedProjectId) {
                    workspace.refreshMeetingPartnerState()
                }

                Button("新規プロジェクト", systemImage: "plus.rectangle.on.folder") {
                    isShowingNewProjectPopover = true
                }
                .labelStyle(.iconOnly)
                .controlSize(.small)
                .help("新しいプロジェクトを作成")
                .popover(isPresented: $isShowingNewProjectPopover) {
                    newProjectPopoverContent
                }
            }

            Spacer()

            // 中央: メインの2モード切替タブ（🎙️ 会議パートナー ⇄ 📚 資料検索・整理）
            Picker("ワークスペースモード", selection: $workspace.activeMode) {
                Label("🎙️ 会議パートナー", systemImage: "waveform.and.person.filled")
                    .tag(WorkspaceMode.meetingPartner)
                Label("📚 資料検索・整理", systemImage: "books.vertical.fill")
                    .tag(WorkspaceMode.knowledgeHub)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 340)

            Spacer()

            // 右側: 現在のAI構成バッジ ＆ 設定・外部LLM連携ボタン
            HStack(spacing: 10) {
                let activeProject = workspace.projectService.project(for: workspace.selectedProjectId)
                let resolved = workspace.modelManager.resolveConfiguration(project: activeProject)

                Text("\(resolved.realtimeSTTModel.name) + \(resolved.llmModel.name)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.secondary.opacity(0.1), in: Capsule())

                Button("設定・連携", systemImage: "slider.horizontal.3") {
                    workspace.isShowingSettingsSheet = true
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var newProjectPopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("新規プロジェクト作成")
                .font(.headline)
            TextField("プロジェクト名", text: $newProjectName)
                .textFieldStyle(.roundedBorder)
            TextField("説明・テーマ", text: $newProjectDesc)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("作成") {
                    guard !newProjectName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    if let proj = try? workspace.projectService.createProject(
                        name: newProjectName,
                        description: newProjectDesc
                    ) {
                        workspace.selectedProjectId = proj.id
                        newProjectName = ""
                        newProjectDesc = ""
                        isShowingNewProjectPopover = false
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}
