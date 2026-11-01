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
        //    自動的に Mnemosift.app バンドルを生成・更新して LaunchServices 経由で起動する
        Self.relaunchInsideAppBundleIfNeeded()

        // 3. GUI アプリとしてウィンドウを前面化
        NSApplication.shared.setActivationPolicy(.regular)
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
    }

    /// 非 .app バンドルからの実行時に Mnemosift.app を自動生成して LaunchServices (`open -W`) で起動する
    private static func relaunchInsideAppBundleIfNeeded() {
        let env = ProcessInfo.processInfo.environment
        guard env["MNEMOSIFT_NO_RELAUNCH"] != "1" else { return }

        let bundlePath = Bundle.main.bundlePath
        // すでに .app バンドルとして動作している場合はそのまま続行
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
        let bundledExecURL = macOSURL.appendingPathComponent("Mnemosift")
        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")

        do {
            try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)

            if FileManager.default.fileExists(atPath: bundledExecURL.path) {
                try FileManager.default.removeItem(at: bundledExecURL)
            }
            try FileManager.default.copyItem(at: execURL, to: bundledExecURL)

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

            // Ad-hoc 署名を適用して TCC が Info.plist を認識できるようにする
            let signProc = Process()
            signProc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            signProc.arguments = ["--force", "--deep", "--sign", "-", appBundleURL.path]
            signProc.standardOutput = Pipe()
            signProc.standardError = Pipe()
            try signProc.run()
            signProc.waitUntilExit()

            // LaunchServices 経由で Mnemosift.app を起動（TCC の責任プロセスを Mnemosift.app 自身にする）
            let openProc = Process()
            openProc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            openProc.arguments = ["-W", appBundleURL.path]
            try openProc.run()
            openProc.waitUntilExit()
            Darwin.exit(openProc.terminationStatus)
        } catch {
            // バンドル生成に失敗した場合でもクラッシュせずそのまま続行（LiveAudioStreamEngine 側のガードが保護）
            return
        }
    }
}
