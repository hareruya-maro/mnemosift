import SwiftUI
import MnemosiftCore

public struct MainWorkspaceView: View {
    @Bindable var workspace: AppWorkspaceController

    public init(workspace: AppWorkspaceController) {
        self.workspace = workspace
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 仕様書 §5.2: 録音状態の常時表示バー（他画面に移動しても常時表示・操作可能）
            if workspace.recordingService.state == .recording || workspace.recordingService.state == .paused {
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
                .padding(.vertical, 8)
                .background(.blue.opacity(0.1))
            }

            NavigationSplitView {
                List(NavigationSection.allCases, selection: $workspace.selectedSection) { section in
                    NavigationLink(value: section) {
                        HStack {
                            Label(section.rawValue, systemImage: section.systemImage)
                            Spacer()
                            badgeForSection(section)
                        }
                    }
                }
                .navigationTitle("Mnemosift")
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Divider()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(.green)
                                .frame(width: 8, height: 8)
                            Text("ローカルファースト・オフライン稼働")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text("プロジェクト選択: \(activeProjectName)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(12)
                }
            } detail: {
                switch workspace.selectedSection {
                case .home:
                    HomeView(workspace: workspace)
                case .recording:
                    RecordingTranscriptionView(workspace: workspace)
                case .meetings:
                    MeetingsView(workspace: workspace)
                case .files:
                    FilesView(workspace: workspace)
                case .searchChat:
                    SearchChatView(workspace: workspace)
                case .projects:
                    ProjectsView(workspace: workspace)
                case .history:
                    ProcessingHistoryView(workspace: workspace)
                case .settings:
                    SettingsView(workspace: workspace)
                }
            }
        }
    }

    private var activeProjectName: String {
        if let pid = workspace.selectedProjectId,
           let proj = workspace.projectService.project(for: pid) {
            return proj.name
        }
        return "未指定（単発モード）"
    }

    @ViewBuilder
    private func badgeForSection(_ section: NavigationSection) -> some View {
        switch section {
        case .recording:
            if workspace.recordingService.state == .recording {
                Text("REC")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.red, in: Capsule())
                    .foregroundStyle(.white)
            }
        case .meetings:
            Text("\(workspace.llmService.meetings.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .files:
            let pendingCount = workspace.documentService.operationHistories.filter { $0.status == .pendingApproval }.count
            if pendingCount > 0 {
                Text("提案\(pendingCount)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.2), in: Capsule())
                    .foregroundStyle(.orange)
            }
        case .projects:
            let candidateCount = workspace.projectService.vocabularies.filter { $0.approvalStatus == .candidate }.count
            if candidateCount > 0 {
                Text("候補\(candidateCount)")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.15), in: Capsule())
                    .foregroundStyle(.blue)
            }
        case .history:
            let activeCount = workspace.jobManager.activeRunningJobsCount
            if activeCount > 0 {
                Text("\(activeCount)")
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.green.opacity(0.2), in: Capsule())
                    .foregroundStyle(.green)
            }
        default:
            EmptyView()
        }
    }
}
