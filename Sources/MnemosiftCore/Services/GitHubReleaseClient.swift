import Foundation

/// GitHub Releases API クライアント
public actor GitHubReleaseClient {
    public let owner: String
    public let repo: String
    private let urlSession: URLSession

    public init(owner: String = "hareruya-maro", repo: String = "mnemosift", urlSession: URLSession = .shared) {
        self.owner = owner
        self.repo = repo
        self.urlSession = urlSession
    }

    /// 最新の安定版リリース情報を取得
    public func fetchLatestRelease() async throws -> GitHubRelease? {
        let endpoint = "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
        guard let url = URL(string: endpoint) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.setValue("Mnemosift-App", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10.0

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        // リリースがまだ1件もない場合は 404 が返る
        if httpResponse.statusCode == 404 {
            return nil
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.init(rawValue: httpResponse.statusCode))
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GitHubRelease.self, from: data)
    }

    /// 現在のバージョンと比較してアップデートが存在するか確認
    public func checkForUpdates(currentVersion: String) async -> UpdateCheckResult {
        do {
            guard let latestRelease = try await fetchLatestRelease() else {
                return .upToDate(currentVersion: currentVersion)
            }

            guard let remoteVersion = latestRelease.semanticVersion else {
                return .upToDate(currentVersion: currentVersion)
            }

            guard let localVersion = SemanticVersion(string: currentVersion) else {
                return .upToDate(currentVersion: currentVersion)
            }

            if localVersion < remoteVersion {
                return .updateAvailable(
                    release: latestRelease,
                    currentVersion: currentVersion,
                    newVersion: latestRelease.tagName
                )
            } else {
                return .upToDate(currentVersion: currentVersion)
            }
        } catch {
            return .failed(error: error.localizedDescription)
        }
    }
}
