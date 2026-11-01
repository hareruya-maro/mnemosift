import Foundation
import AppKit
import SwiftUI
import MnemosiftCore

/// アプリのアップデート状態
public enum AppUpdateStatus: Equatable, Sendable {
    case idle
    case checking
    case upToDate(version: String)
    case updateAvailable(release: GitHubRelease)
    case downloading(progress: Double)
    case installing
    case failed(message: String)

    public static func == (lhs: AppUpdateStatus, rhs: AppUpdateStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.checking, .checking), (.installing, .installing):
            return true
        case let (.upToDate(v1), .upToDate(v2)):
            return v1 == v2
        case let (.updateAvailable(r1), .updateAvailable(r2)):
            return r1.id == r2.id
        case let (.downloading(p1), .downloading(p2)):
            return abs(p1 - p2) < 0.001
        case let (.failed(m1), .failed(m2)):
            return m1 == m2
        default:
            return false
        }
    }
}

/// GitHub Releases を利用したアプリ内自動更新マネージャー
@Observable
@MainActor
public final class AppUpdateService: NSObject, @unchecked Sendable {
    public static let shared = AppUpdateService()

    public private(set) var status: AppUpdateStatus = .idle
    public private(set) var lastCheckedDate: Date?
    public var isShowingUpdateSheet: Bool = false

    /// 起動時に自動チェックするかどうか (UserDefaults)
    public var automaticallyCheckForUpdates: Bool {
        get {
            UserDefaults.standard.object(forKey: "automaticallyCheckForUpdates") as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "automaticallyCheckForUpdates")
        }
    }

    /// スキップされたバージョン
    public var ignoredVersion: String? {
        get {
            UserDefaults.standard.string(forKey: "ignoredUpdateVersion")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "ignoredUpdateVersion")
        }
    }

    public let client: GitHubReleaseClient

    public override init() {
        self.client = GitHubReleaseClient(owner: "hareruya-maro", repo: "mnemosift")
        super.init()
    }

    /// 現在のアプリバージョン (例: "0.1.0")
    public var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    /// アップデートの確認を実行
    /// - Parameter isUserInitiated: ユーザーによる手動確認かどうか
    public func checkForUpdates(isUserInitiated: Bool = false) async {
        guard status != .checking && !isDownloading else { return }

        status = .checking
        lastCheckedDate = Date()

        let result = await client.checkForUpdates(currentVersion: currentVersion)

        switch result {
        case .upToDate:
            status = .upToDate(version: currentVersion)
            if isUserInitiated {
                isShowingUpdateSheet = true
            }

        case let .updateAvailable(release, _, _):
            // ユーザー手動でなく、スキップ指定されたバージョンの場合は通知しない
            if !isUserInitiated, let ignored = ignoredVersion, ignored == release.tagName {
                status = .idle
                return
            }
            status = .updateAvailable(release: release)
            isShowingUpdateSheet = true

        case let .failed(error):
            status = .failed(message: error)
            if isUserInitiated {
                isShowingUpdateSheet = true
            }
        }
    }

    /// ダウンロード中かどうか
    public var isDownloading: Bool {
        if case .downloading = status { return true }
        return false
    }

    /// このバージョンをスキップ
    public func ignoreVersion(_ tagName: String) {
        ignoredVersion = tagName
        status = .idle
        isShowingUpdateSheet = false
    }

    /// GitHub Releases ページをブラウザで開く
    public func openReleaseWebPage(url: URL? = nil) {
        let targetURL = url ?? URL(string: "https://github.com/hareruya-maro/mnemosift/releases")!
        NSWorkspace.shared.open(targetURL)
    }

    /// 最新リリースのZIPをダウンロードしてアプリを置換・再起動
    public func downloadAndInstall(release: GitHubRelease) async {
        guard let zipAsset = release.zipAsset else {
            status = .failed(message: "配布用ZIPパッケージが見つかりませんでした。ブラウザからダウンロードしてください。")
            return
        }

        let isRunningInAppBundle = Bundle.main.bundlePath.hasSuffix(".app")
        let currentAppURL = Bundle.main.bundleURL

        // 1. ダウンロードの実行
        status = .downloading(progress: 0.05)

        do {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("mnemosift_update_\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

            let zipFileURL = tempDir.appendingPathComponent(zipAsset.name)

            // ダウンロードタスク
            var request = URLRequest(url: zipAsset.browserDownloadURL)
            request.setValue("Mnemosift-Updater", forHTTPHeaderField: "User-Agent")

            let (downloadedURL, _) = try await downloadWithProgress(request: request)
            try FileManager.default.moveItem(at: downloadedURL, to: zipFileURL)

            status = .installing

            // 2. 解凍
            let extractedDir = tempDir.appendingPathComponent("extracted", isDirectory: true)
            try FileManager.default.createDirectory(at: extractedDir, withIntermediateDirectories: true)

            let unzipProc = Process()
            unzipProc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzipProc.arguments = ["-x", "-k", zipFileURL.path, extractedDir.path]
            try unzipProc.run()
            unzipProc.waitUntilExit()

            guard unzipProc.terminationStatus == 0 else {
                throw NSError(domain: "AppUpdateService", code: 1, userInfo: [NSLocalizedDescriptionKey: "ZIPの展開に失敗しました"])
            }

            // 展開された .app を探索
            let contents = try FileManager.default.contentsOfDirectory(at: extractedDir, includingPropertiesForKeys: nil)
            guard let newAppURL = contents.first(where: { $0.pathExtension == "app" }) else {
                throw NSError(domain: "AppUpdateService", code: 2, userInfo: [NSLocalizedDescriptionKey: "展開先で Mnemosift.app が見つかりませんでした"])
            }

            // 3. アプリケーション置換と再起動
            if !isRunningInAppBundle {
                // 開発環境 (swift run / Xcode) の場合: 置換は行わず通知
                status = .upToDate(version: release.tagName)
                openReleaseWebPage(url: release.htmlURL)
                return
            }

            // 本番環境 (.app 実行): 安全なスワップスクリプトを生成して起動＆自分を終了
            try launchSwapScriptAndRelaunch(
                currentAppPath: currentAppURL.path,
                newAppPath: newAppURL.path,
                tempDir: tempDir.path
            )

        } catch {
            status = .failed(message: "アップデート処理に失敗しました: \(error.localizedDescription)")
        }
    }

    /// ダウンロード進捗を監視しながらファイルを保存
    private func downloadWithProgress(request: URLRequest) async throws -> (URL, URLResponse) {
        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        let totalExpected = response.expectedContentLength

        let tempFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".tmp")
        FileManager.default.createFile(atPath: tempFileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tempFileURL)

        var downloadedBytes: Int64 = 0
        var lastReportedTime = Date()

        for try await byte in asyncBytes {
            handle.write(Data([byte]))
            downloadedBytes += 1

            if Date().timeIntervalSince(lastReportedTime) > 0.1 {
                lastReportedTime = Date()
                if totalExpected > 0 {
                    let progress = Double(downloadedBytes) / Double(totalExpected)
                    await MainActor.run {
                        self.status = .downloading(progress: min(max(progress, 0.05), 0.95))
                    }
                }
            }
        }
        try handle.close()

        await MainActor.run {
            self.status = .downloading(progress: 1.0)
        }

        return (tempFileURL, response)
    }

    /// 一時スクリプトで古いアプリと新しいアプリをアトミックに入れ替え、再起動する
    private func launchSwapScriptAndRelaunch(currentAppPath: String, newAppPath: String, tempDir: String) throws {
        let scriptPath = (tempDir as NSString).appendingPathComponent("swap_and_relaunch.sh")
        let scriptContent = """
        #!/usr/bin/env bash
        set -e
        # Mnemosift プロセスが完全に終了するのを少し待機
        sleep 1

        CURRENT="\(currentAppPath)"
        NEW="\(newAppPath)"
        BACKUP="${CURRENT}.old.\(UUID().uuidString)"

        # 隔離属性 (Quarantine) の除去
        xattr -dr com.apple.quarantine "$NEW" 2>/dev/null || true

        # バックアップ & スワップ
        mv "$CURRENT" "$BACKUP"
        if cp -R "$NEW" "$CURRENT"; then
            rm -rf "$BACKUP"
            rm -rf "\(tempDir)"
            # 新しいアプリを起動
            open "$CURRENT"
        else
            # 失敗時はロールバック
            mv "$BACKUP" "$CURRENT"
            open "$CURRENT"
            exit 1
        fi
        """

        try scriptContent.write(toFile: scriptPath, atomically: true, encoding: .utf8)

        let chmodProc = Process()
        chmodProc.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmodProc.arguments = ["+x", scriptPath]
        try chmodProc.run()
        chmodProc.waitUntilExit()

        // バックグラウンドでスワップスクリプトを起動
        let runner = Process()
        runner.executableURL = URL(fileURLWithPath: "/bin/bash")
        runner.arguments = [scriptPath]
        try runner.run()

        // 現在のアプリを終了
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NSApplication.shared.terminate(nil)
        }
    }
}
