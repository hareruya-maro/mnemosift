import SwiftUI
import AppKit
import MnemosiftCore

/// 右上の「⚙️ 設定・連携」から開く統合モーダルシート
/// - タブ1: AIモデル・音声設定 (`SettingsView` の機能)
/// - タブ2: 外部LLM連携（Claude Desktop / Cursor 用 MCP サーバー設定 JSON と CLI コマンドのワンクリックコピー）
/// - タブ3: バックグラウンド処理履歴・Phase 0 技術検証ベンチマーク (`ProcessingHistoryView` の機能)
public struct SettingsAndToolsSheet: View {
    @Bindable var workspace: AppWorkspaceController

    public enum SettingsTab: String, CaseIterable, Identifiable {
        case models = "🤖 AIモデル・保存設定"
        case googleDrive = "☁️ Google Drive連携"
        case externalTools = "🔌 外部LLM連携 (MCP / CLI)"
        case diagnostics = "⚡ 処理履歴・技術検証"
        case updates = "🚀 アプリ更新"
        public var id: String { rawValue }
    }

    @State private var selectedTab: SettingsTab = .models

    public init(workspace: AppWorkspaceController) {
        self.workspace = workspace
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("設定・AIモデル管理・外部LLM連携")
                    .font(.headline)
                Spacer()
                Picker("設定タブ", selection: $selectedTab) {
                    ForEach(SettingsTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 760)
                Spacer()
                Button("閉じる", systemImage: "xmark.circle.fill") {
                    workspace.isShowingSettingsSheet = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(16)
            .background(.regularMaterial)

            Divider()

            switch selectedTab {
            case .models:
                SettingsView(workspace: workspace)
            case .googleDrive:
                GoogleDriveSyncSettingsView(workspace: workspace)
            case .externalTools:
                externalToolBridgeTabView
            case .diagnostics:
                ProcessingHistoryView(workspace: workspace)
            case .updates:
                UpdateSheetView()
            }
        }
        .frame(minWidth: 920, minHeight: 620)
    }

    private var externalToolBridgeTabView: some View {
        let executablePath = ProcessInfo.processInfo.arguments.first ?? "/Users/haruya/dev/Mnemosift/.build/debug/Mnemosift"
        let mcpConfig = ExternalToolBridge.sampleMCPClientConfigJSON(executablePath: executablePath)
        let cliHelp = ExternalToolBridge.helpText()

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("1. MCP (Model Context Protocol) サーバー連携", systemImage: "network")
                            .font(.headline)
                        Spacer()
                        Button("MCP設定JSONをコピー", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(mcpConfig, forType: .string)
                            workspace.statusBannerMessage = "MCPサーバー設定JSONをクリップボードにコピーしました"
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    Text("Claude Desktop や Cursor 等の設定ファイルに以下の JSON を追加すると、外部LLMが `mnemosift_search` や `mnemosift_list_meetings` ツールを自動呼び出しできるようになります。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(mcpConfig)
                        .font(.system(.caption, design: .monospaced))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        .textSelection(.enabled)
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("2. CLI コマンド連携（Claude Code / Codex / Antigravity / Raycast 用）", systemImage: "terminal")
                            .font(.headline)
                        Spacer()
                        Button("CLIコマンド例をコピー", systemImage: "doc.on.doc") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(executablePath) search \"決定事項\" --json", forType: .string)
                            workspace.statusBannerMessage = "CLI検索コマンドをコピーしました"
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Text("ターミナルやエージェントツールの Bash から直接ローカルナレッジを検索・取得できます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(cliHelp)
                        .font(.system(.caption, design: .monospaced))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        .textSelection(.enabled)
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
            .padding(20)
        }
    }
}
