import SwiftUI
import AppKit
import Darwin
import MnemosiftCore

@main
struct MnemosiftApp: App {
    @State private var workspace: AppWorkspaceController

    init() {
        let args = ProcessInfo.processInfo.arguments

        // 1. コマンドライン引数（search / meetings / documents / vocabulary / mcp）が指定されている場合はCLI/MCPとして即実行
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

        // 2. `swift run Mnemosift` 等でターミナルから非 .app バンドルとして直接起動された場合、
        //    macOS TCC のプライバシー強制終了 (__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__) を防ぐため、
        //    自動的に Mnemosift.app バンドル（アプリアイコン付き）を生成・更新して LaunchServices 経由で起動する
        Self.relaunchInsideAppBundleIfNeeded()

        // 3. GUI アプリとしてアイコン適用＆ウィンドウを前面化
        NSApplication.shared.setActivationPolicy(.regular)
        if let icon = Self.loadAppIconImage() {
            NSApplication.shared.applicationIconImage = icon
        }
        NSApplication.shared.activate(ignoringOtherApps: true)

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

        // §8.3 メニューバー常駐コントロール（同期状態表示・手動同期・一時停止・環境設定）
        MenuBarExtra("Mnemosift Google Drive", systemImage: menuBarIconName) {
            GoogleDriveMenuBarView(workspace: workspace)
        }
    }

    private var menuBarIconName: String {
        switch workspace.googleDriveSyncService.syncState {
        case .syncing:
            return "arrow.triangle.2.circlepath.circle.fill"
        case .paused:
            return "pause.circle.fill"
        case .offline:
            return "wifi.slash"
        case .authRequired, .error:
            return "exclamationmark.circle.fill"
        case .idle:
            return "cloud.fill"
        }
    }

    /// アプリアイコン画像を読み込む
    public static func loadAppIconImage() -> NSImage? {
        if let icnsURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: icnsURL) {
            return img
        }
        if let pngURL = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let img = NSImage(contentsOf: pngURL) {
            return img
        }
        if let modulePNG = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let img = NSImage(contentsOf: modulePNG) {
            return img
        }
        if let moduleICNS = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: moduleICNS) {
            return img
        }
        return nil
    }

    /// 非 .app バンドルからの実行時に Mnemosift.app を自動生成して LaunchServices (`open -W`) で起動する
    private static func relaunchInsideAppBundleIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        guard env["MNEMOSIFT_NO_RELAUNCH"] != "1" else { return }

        let bundlePath = Bundle.main.bundlePath
        if bundlePath.hasSuffix(".app") {
            return
        }

        guard let executablePath = ProcessInfo.processInfo.arguments.first else { return }
        let execURL = URL(fileURLWithPath: executablePath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: execURL.path) else { return }

        let buildDir = execURL.deletingLastPathComponent()
        let appBundleURL = buildDir.appendingPathComponent("Mnemosift.app", isDirectory: true)
        let contentsURL = appBundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        let bundledExecURL = macOSURL.appendingPathComponent("Mnemosift")
        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")

        do {
            try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: resourcesURL, withIntermediateDirectories: true)

            if FileManager.default.fileExists(atPath: bundledExecURL.path) {
                try FileManager.default.removeItem(at: bundledExecURL)
            }
            try FileManager.default.copyItem(at: execURL, to: bundledExecURL)

            // SwiftPM リソースバンドル (Mnemosift_MnemosiftApp.bundle) および AppIcon.icns / AppIcon.png をコピー
            let resourceBundleName = "Mnemosift_MnemosiftApp.bundle"
            let srcResourceBundle = buildDir.appendingPathComponent(resourceBundleName)
            let dstResourceBundle = resourcesURL.appendingPathComponent(resourceBundleName)
            if FileManager.default.fileExists(atPath: srcResourceBundle.path) {
                try? FileManager.default.removeItem(at: dstResourceBundle)
                try? FileManager.default.copyItem(at: srcResourceBundle, to: dstResourceBundle)
            }

            if let icnsSrc = Bundle.module.url(forResource: "AppIcon", withExtension: "icns") {
                let icnsDst = resourcesURL.appendingPathComponent("AppIcon.icns")
                try? FileManager.default.removeItem(at: icnsDst)
                try? FileManager.default.copyItem(at: icnsSrc, to: icnsDst)
            }
            if let pngSrc = Bundle.module.url(forResource: "AppIcon", withExtension: "png") {
                let pngDst = resourcesURL.appendingPathComponent("AppIcon.png")
                try? FileManager.default.removeItem(at: pngDst)
                try? FileManager.default.copyItem(at: pngSrc, to: pngDst)
            }

            let infoPlistXML = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleIdentifier</key>
                <string>com.mnemosift.app</string>
                <key>CFBundleName</key>
                <string>Mnemosift</string>
                <key>CFBundleDisplayName</key>
                <string>Mnemosift</string>
                <key>CFBundleExecutable</key>
                <string>Mnemosift</string>
                <key>CFBundleIconFile</key>
                <string>AppIcon</string>
                <key>CFBundleIconName</key>
                <string>AppIcon</string>
                <key>CFBundlePackageType</key>
                <string>APPL</string>
                <key>CFBundleShortVersionString</key>
                <string>0.1.0</string>
                <key>CFBundleVersion</key>
                <string>1</string>
                <key>LSMinimumSystemVersion</key>
                <string>14.0</string>
                <key>NSHighResolutionCapable</key>
                <true/>
                <key>NSMicrophoneUsageDescription</key>
                <string>会議の音声を録音し、ローカルAIでリアルタイムに文字起こしするためにマイクを使用します。</string>
                <key>NSSpeechRecognitionUsageDescription</key>
                <string>録音された音声をデバイス上でリアルタイムに文字起こしするために音声認識を使用します。</string>
                <key>NSScreenCaptureUsageDescription</key>
                <string>YouTubeやWeb会議などのシステム音声をキャプチャして文字起こしするために画面とシステムオーディオの録音を使用します。</string>
            </dict>
            </plist>
            """
            try infoPlistXML.write(to: infoPlistURL, atomically: true, encoding: .utf8)

            if let iconImg = loadAppIconImage() {
                NSWorkspace.shared.setIcon(iconImg, forFile: appBundleURL.path, options: [])
            }

            // Ad-hoc 署名を適用して TCC が Info.plist を認識できるようにする
            let signProc = Process()
            signProc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            signProc.arguments = ["--force", "--deep", "--sign", "-", appBundleURL.path]
            signProc.standardOutput = Pipe()
            signProc.standardError = Pipe()
            try signProc.run()
            signProc.waitUntilExit()

            // LaunchServices 経由で Mnemosift.app を起動
            let openProc = Process()
            openProc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            openProc.arguments = ["-W", appBundleURL.path]
            try openProc.run()
            openProc.waitUntilExit()
            Darwin.exit(openProc.terminationStatus)
        } catch {
            return
        }
    }
}

// MARK: - §8.3 メニューバー常駐ビュー (`GoogleDriveMenuBarView`)

public struct GoogleDriveMenuBarView: View {
    @Bindable var workspace: AppWorkspaceController

    public init(workspace: AppWorkspaceController) {
        self.workspace = workspace
    }

    public var body: some View {
        let syncService = workspace.googleDriveSyncService

        VStack(alignment: .leading, spacing: 6) {
            Text("☁️ Google Drive 同期ステータス")
                .font(.headline)

            HStack {
                Text("状態: \(syncService.syncState.displayName)")
                    .font(.subheadline)
            }

            if let last = syncService.lastSyncedAt {
                Text("最終同期: \(last.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let progress = syncService.syncProgress {
                Text(progress.phaseDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Button("今すぐ同期を実行", systemImage: "arrow.triangle.2.circlepath") {
                Task {
                    await syncService.syncAllConnectedAccounts(triggerReason: "menubar_manual")
                }
            }
            .disabled(syncService.syncFolders.isEmpty || syncService.configuration.isPaused)

            Button(syncService.configuration.isPaused ? "同期を再開する" : "同期を一時停止する",
                   systemImage: syncService.configuration.isPaused ? "play.fill" : "pause.fill") {
                syncService.setSyncPaused(!syncService.configuration.isPaused)
            }

            Divider()

            Button("同期設定・フォルダ管理を開く...", systemImage: "gearshape") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                workspace.isShowingSettingsSheet = true
            }

            Divider()

            Button("Mnemosift を終了", role: .destructive) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(8)
    }
}
