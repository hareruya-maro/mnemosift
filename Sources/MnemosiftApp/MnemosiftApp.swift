import SwiftUI
import MnemosiftCore

@main
struct MnemosiftApp: App {
    @State private var workspace: AppWorkspaceController

    init() {
        let controller = (try? AppWorkspaceController()) ?? {
            let fallbackPath = FileManager.default.temporaryDirectory
                .appendingPathComponent("mnemosift-fallback.sqlite3").path
            return try! AppWorkspaceController(databasePath: fallbackPath)
        }()
        _workspace = State(initialValue: controller)
    }

    var body: some Scene {
        WindowGroup("Mnemosift — ローカルAIワークスペース") {
            MainWorkspaceView(workspace: workspace)
                .frame(minWidth: 1120, minHeight: 740)
        }
        .windowResizability(.contentMinSize)
    }
}
