import Foundation
import Testing
@testable import MnemosiftCore

@Suite("GitHub Release & セマンティックバージョニング テストスイート")
struct SemanticVersionTests {

    @Test("SemanticVersion の文字列パース")
    func testVersionParsing() {
        let v1 = SemanticVersion(string: "0.1.0")
        #expect(v1?.major == 0)
        #expect(v1?.minor == 1)
        #expect(v1?.patch == 0)
        #expect(v1?.prerelease == nil)

        let v2 = SemanticVersion(string: "v1.2.3")
        #expect(v2?.major == 1)
        #expect(v2?.minor == 2)
        #expect(v2?.patch == 3)

        let v3 = SemanticVersion(string: "2.0.0-beta.1")
        #expect(v3?.major == 2)
        #expect(v3?.minor == 0)
        #expect(v3?.patch == 0)
        #expect(v3?.prerelease == "beta.1")
    }

    @Test("SemanticVersion のバージョン比較 (新旧判定)")
    func testVersionComparison() {
        let current = SemanticVersion(string: "0.1.0")!
        let patchNewer = SemanticVersion(string: "0.1.1")!
        let minorNewer = SemanticVersion(string: "0.2.0")!
        let majorNewer = SemanticVersion(string: "1.0.0")!
        let older = SemanticVersion(string: "0.0.9")!

        #expect(current < patchNewer)
        #expect(current < minorNewer)
        #expect(current < majorNewer)
        #expect(older < current)
        #expect(!(current < current))

        // プレリリースと正式版の比較
        let beta = SemanticVersion(string: "1.0.0-beta.1")!
        let release = SemanticVersion(string: "1.0.0")!
        #expect(beta < release)
    }

    @Test("GitHubRelease JSON デコードとアセット選択")
    func testGitHubReleaseDecoding() throws {
        let json = """
        {
            "id": 12345,
            "tag_name": "v0.2.0",
            "name": "Mnemosift v0.2.0 リリース",
            "body": "- 自動更新機能を追加\\n- 音声認識の精度向上",
            "draft": false,
            "prerelease": false,
            "html_url": "https://github.com/hareruya-maro/mnemosift/releases/tag/v0.2.0",
            "published_at": "2026-11-01T12:00:00Z",
            "assets": [
                {
                    "id": 1,
                    "name": "Mnemosift-v0.2.0-macOS-arm64.zip",
                    "size": 45000000,
                    "download_count": 10,
                    "browser_download_url": "https://github.com/hareruya-maro/mnemosift/releases/download/v0.2.0/Mnemosift-v0.2.0-macOS-arm64.zip",
                    "content_type": "application/zip"
                },
                {
                    "id": 2,
                    "name": "Mnemosift-v0.2.0.dmg",
                    "size": 47000000,
                    "download_count": 5,
                    "browser_download_url": "https://github.com/hareruya-maro/mnemosift/releases/download/v0.2.0/Mnemosift-v0.2.0.dmg",
                    "content_type": "application/x-apple-diskimage"
                }
            ]
        }
        """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(GitHubRelease.self, from: Data(json.utf8))

        #expect(release.tagName == "v0.2.0")
        #expect(release.semanticVersion == SemanticVersion(major: 0, minor: 2, patch: 0))
        #expect(release.zipAsset?.name == "Mnemosift-v0.2.0-macOS-arm64.zip")
        #expect(release.dmgAsset?.name == "Mnemosift-v0.2.0.dmg")
    }
}
