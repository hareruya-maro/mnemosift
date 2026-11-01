import SwiftUI
import Darwin
import MnemosiftCore

@main
struct MnemosiftApp: App {
    @State private var workspace: AppWorkspaceController

    init() {
        // コマンドライン引数（search / meetings / documents / vocabulary / mcp）が指定されている場合はCLI/MCPとして即実行
        let args = ProcessInfo.processInfo.arguments
        if args.count >= 2 {
            let sub = args[1]
            if !sub.hasPrefix("-NS") && !sub.hasPrefix("-Apple") && !sub.hasPrefix("-psn_") {
                if let ws = try? AppWorkspaceController(seedDemoDataIfEmpty: false) {
                    let bridge = ExternalToolBridge(workspace: ws)
                    if sub == "mcp" {
                        while let line = readLine() {
                            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { continue }
                            if let reply = bridge.handleMCPJSONRPCRequest(jsonLine: trimmed) {
                                FileHandle.standardOutput.write(Data((reply + "\n").utf8))
                            }
                        }
                        Darwin.exit(0)
                    } else {
                        let out: String
                        let asJSON = args.contains("--json")
                        switch sub {
                        case "search":
                            let q = args.dropFirst(2).filter { !$0.hasPrefix("--") }.joined(separator: " ")
                            out = bridge.runSearchCommand(query: q, asJSON: asJSON)
                        case "meetings":
                            out = bridge.runMeetingsCommand(asJSON: asJSON)
                        case "documents":
                            out = bridge.runDocumentsCommand(asJSON: asJSON)
                        case "vocabulary":
                            out = bridge.runVocabularyCommand(asJSON: asJSON)
                        default:
                            out = ExternalToolBridge.helpText()
                        }
                        FileHandle.standardOutput.write(Data((out + "\n").utf8))
                        Darwin.exit(0)
                    }
                }
            }
        }

        let controller = (try? AppWorkspaceController()) ?? {
            let fallbackPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("mnemosift-fallback.sqlite3").path
            return try! AppWorkspaceController(databasePath: fallbackPath)
        }()
        _workspace = State(initialValue: controller)
    }

    var body: some Scene {
        WindowGroup("Mnemosift — 会議のAIパートナー & ローカルナレッジ") {
            MainWorkspaceView(workspace: workspace)
                .frame(minWidth: 1120, minHeight: 740)
        }
        .windowResizability(.contentMinSize)
    }
}
