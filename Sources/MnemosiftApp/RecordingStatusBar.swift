import SwiftUI
import MnemosiftCore

public struct RecordingStatusBar: View {
    @Bindable var workspace: AppWorkspaceController

    public init(workspace: AppWorkspaceController) {
        self.workspace = workspace
    }

    public var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Circle()
                    .fill(workspace.recordingService.state == .recording ? .red : .orange)
                    .frame(width: 10, height: 10)
                Text(workspace.recordingService.state.rawValue)
                    .font(.subheadline.bold())
                if let rec = workspace.recordingService.activeRecording {
                    Text("『\(rec.title)』(\(rec.audioSource.displayName))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text(LocalLLMAdapter.formatTimestamp(workspace.recordingService.elapsedSeconds))
                .font(.system(.subheadline, design: .monospaced).bold())

            HStack(spacing: 4) {
                Text("入力レベル:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ProgressView(value: workspace.recordingService.inputLevel, total: 1.0)
                    .frame(width: 90)
            }

            Spacer()

            if workspace.recordingService.state == .recording {
                Button("一時停止", systemImage: "pause.fill") {
                    workspace.recordingService.pauseRecording()
                }
                .controlSize(.small)
            } else if workspace.recordingService.state == .paused {
                Button("再開", systemImage: "play.fill") {
                    workspace.recordingService.resumeRecording()
                }
                .controlSize(.small)
            }

            Button("停止", systemImage: "stop.fill") {
                _ = try? workspace.recordingService.stopRecording()
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)

            Button("会議パートナーへ戻る", systemImage: "arrow.up.right.square") {
                workspace.activeMode = .meetingPartner
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.red.opacity(0.12))
    }
}
