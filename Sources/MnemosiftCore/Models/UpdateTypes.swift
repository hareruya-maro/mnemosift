import Foundation

/// セマンティックバージョニング表現 (SemVer 2.0 準拠)
public struct SemanticVersion: Comparable, CustomStringConvertible, Codable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let prerelease: String?
    public let buildMetadata: String?

    public init(major: Int, minor: Int, patch: Int, prerelease: String? = nil, buildMetadata: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
        self.buildMetadata = buildMetadata
    }

    /// "v1.2.3", "1.2.3-beta.1+2024", "0.1.0" などの文字列からパース
    public init?(string: String) {
        var raw = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("v") || raw.hasPrefix("V") {
            raw.removeFirst()
        }

        // ビルドメタデータの分離 (+)
        let plusComponents = raw.split(separator: "+", maxSplits: 1).map(String.init)
        let mainAndPrerelease = plusComponents[0]
        self.buildMetadata = plusComponents.count > 1 ? plusComponents[1] : nil

        // プレリリースの分離 (-)
        let hyphenComponents = mainAndPrerelease.split(separator: "-", maxSplits: 1).map(String.init)
        let numbersPart = hyphenComponents[0]
        self.prerelease = hyphenComponents.count > 1 ? hyphenComponents[1] : nil

        // バージョン番号部分 (1.2.3)
        let numbers = numbersPart.split(separator: ".").compactMap { Int($0) }
        guard !numbers.isEmpty else { return nil }

        self.major = numbers[0]
        self.minor = numbers.count > 1 ? numbers[1] : 0
        self.patch = numbers.count > 2 ? numbers[2] : 0
    }

    public var description: String {
        var str = "\(major).\(minor).\(patch)"
        if let prerelease {
            str += "-\(prerelease)"
        }
        if let buildMetadata {
            str += "+\(buildMetadata)"
        }
        return str
    }

    // Comparable 実装
    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major {
            return lhs.major < rhs.major
        }
        if lhs.minor != rhs.minor {
            return lhs.minor < rhs.minor
        }
        if lhs.patch != rhs.patch {
            return lhs.patch < rhs.patch
        }

        // プレリリースなし（正式版）はプレリリースあり（ベータ等）より新しい
        switch (lhs.prerelease, rhs.prerelease) {
        case (.none, .none):
            return false
        case (.none, .some):
            return false
        case (.some, .none):
            return true
        case let (.some(lPre), .some(rPre)):
            return lPre.localizedStandardCompare(rPre) == .orderedAscending
        }
    }
}

/// GitHub Releases API から取得したリリース情報 DTO
public struct GitHubRelease: Codable, Identifiable, Sendable {
    public let id: Int
    public let tagName: String
    public let name: String?
    public let body: String?
    public let draft: Bool
    public let prerelease: Bool
    public let htmlURL: URL
    public let publishedAt: Date?
    public let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
        case name
        case body
        case draft
        case prerelease
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case assets
    }

    /// タグ名からセマンティックバージョンを取得
    public var semanticVersion: SemanticVersion? {
        SemanticVersion(string: tagName)
    }

    /// 表示用タイトル
    public var displayTitle: String {
        name?.isEmpty == false ? name! : tagName
    }

    /// 配布用の ZIP アセット（arm64 や macOS を優先、なければ最初の ZIP）
    public var zipAsset: GitHubReleaseAsset? {
        let zipAssets = assets.filter { $0.name.hasSuffix(".zip") }
        if let arm64 = zipAssets.first(where: { $0.name.localizedCaseInsensitiveContains("arm64") }) {
            return arm64
        }
        if let mac = zipAssets.first(where: { $0.name.localizedCaseInsensitiveContains("mac") }) {
            return mac
        }
        return zipAssets.first
    }

    /// 配布用の DMG アセット
    public var dmgAsset: GitHubReleaseAsset? {
        assets.first(where: { $0.name.hasSuffix(".dmg") })
    }
}

/// GitHub Release の添付ファイル情報
public struct GitHubReleaseAsset: Codable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let size: Int
    public let downloadCount: Int
    public let browserDownloadURL: URL
    public let contentType: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case size
        case downloadCount = "download_count"
        case browserDownloadURL = "browser_download_url"
        case contentType = "content_type"
    }

    /// 人間が読みやすいファイルサイズ表記
    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

/// アップデート確認結果
public enum UpdateCheckResult: Sendable {
    case upToDate(currentVersion: String)
    case updateAvailable(release: GitHubRelease, currentVersion: String, newVersion: String)
    case failed(error: String)
}
