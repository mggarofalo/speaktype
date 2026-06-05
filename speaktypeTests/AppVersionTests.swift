import XCTest
@testable import speaktype

final class AppVersionTests: XCTestCase {

    // MARK: - isNewerVersion

    func testEqualVersionsAreNotNewer() {
        XCTAssertFalse(AppVersion.isNewerVersion("1.2.3", than: "1.2.3"))
    }

    func testPatchBump() {
        XCTAssertTrue(AppVersion.isNewerVersion("1.2.4", than: "1.2.3"))
        XCTAssertFalse(AppVersion.isNewerVersion("1.2.3", than: "1.2.4"))
    }

    func testMinorBump() {
        XCTAssertTrue(AppVersion.isNewerVersion("1.3.0", than: "1.2.9"))
        XCTAssertFalse(AppVersion.isNewerVersion("1.2.9", than: "1.3.0"))
    }

    func testMajorBump() {
        XCTAssertTrue(AppVersion.isNewerVersion("2.0.0", than: "1.99.99"))
        XCTAssertFalse(AppVersion.isNewerVersion("1.99.99", than: "2.0.0"))
    }

    func testNumericComparisonNotLexicographic() {
        // The whole point of .numeric: "1.10" must be newer than "1.9",
        // which a plain string compare would get wrong.
        XCTAssertTrue(AppVersion.isNewerVersion("1.10", than: "1.9"))
        XCTAssertTrue(AppVersion.isNewerVersion("1.67", than: "1.62"))
    }

    func testDifferentComponentCount() {
        XCTAssertTrue(AppVersion.isNewerVersion("1.2.1", than: "1.2"))
        XCTAssertFalse(AppVersion.isNewerVersion("1.2", than: "1.2.1"))
    }

    // MARK: - init(from: GitHubRelease)

    private func makeRelease(
        tagName: String = "v1.2.3",
        body: String = "notes",
        htmlUrl: String = "https://example.com/release",
        publishedAt: String = "2026-01-07T12:00:00Z",
        assets: [GitHubAsset] = []
    ) -> GitHubRelease {
        GitHubRelease(
            tagName: tagName,
            body: body,
            htmlUrl: htmlUrl,
            publishedAt: publishedAt,
            assets: assets
        )
    }

    func testInitStripsLeadingVFromTag() {
        let version = AppVersion(from: makeRelease(tagName: "v1.0.1"))
        XCTAssertEqual(version.version, "1.0.1")
    }

    func testInitLeavesTagWithoutVPrefixIntact() {
        let version = AppVersion(from: makeRelease(tagName: "2.5.0"))
        XCTAssertEqual(version.version, "2.5.0")
    }

    func testInitParsesReleaseNotesTrimmingAndDroppingBlankLines() {
        let body = "  First line  \n\n   \nSecond line\n"
        let version = AppVersion(from: makeRelease(body: body))
        XCTAssertEqual(version.releaseNotes, ["First line", "Second line"])
    }

    func testInitPrefersDmgAssetOverHtmlUrl() {
        let assets = [
            GitHubAsset(name: "checksums.txt", browserDownloadUrl: "https://example.com/checksums.txt"),
            GitHubAsset(name: "speaktype.dmg", browserDownloadUrl: "https://example.com/speaktype.dmg"),
        ]
        let version = AppVersion(from: makeRelease(htmlUrl: "https://example.com/page", assets: assets))
        XCTAssertEqual(version.downloadURL, "https://example.com/speaktype.dmg")
    }

    func testInitFallsBackToHtmlUrlWhenNoDmg() {
        let assets = [
            GitHubAsset(name: "checksums.txt", browserDownloadUrl: "https://example.com/checksums.txt"),
        ]
        let version = AppVersion(from: makeRelease(htmlUrl: "https://example.com/page", assets: assets))
        XCTAssertEqual(version.downloadURL, "https://example.com/page")
    }

    func testInitFallsBackToHtmlUrlWhenNoAssets() {
        let version = AppVersion(from: makeRelease(htmlUrl: "https://example.com/page", assets: []))
        XCTAssertEqual(version.downloadURL, "https://example.com/page")
    }

    func testInitSetsBuildNumberAndIsRequiredDefaults() {
        let version = AppVersion(from: makeRelease())
        XCTAssertEqual(version.buildNumber, "0")
        XCTAssertFalse(version.isRequired)
    }

    func testInitParsesISO8601PublishedDate() {
        let version = AppVersion(from: makeRelease(publishedAt: "2026-01-07T12:00:00Z"))
        let expected = ISO8601DateFormatter().date(from: "2026-01-07T12:00:00Z")
        XCTAssertEqual(version.releaseDate, expected)
    }

    func testInitFallsBackToNowForMalformedPublishedDate() {
        // A non-ISO8601 string must not crash; it falls back to "now".
        let before = Date()
        let version = AppVersion(from: makeRelease(publishedAt: "not a date"))
        let after = Date()
        XCTAssertGreaterThanOrEqual(version.releaseDate, before)
        XCTAssertLessThanOrEqual(version.releaseDate, after)
    }

    // MARK: - GitHubRelease / GitHubAsset decoding

    func testGitHubReleaseDecodesSnakeCaseKeys() throws {
        let json = """
        {
          "tag_name": "v1.5.0",
          "body": "release body",
          "html_url": "https://example.com/r",
          "published_at": "2026-02-01T00:00:00Z",
          "assets": [
            { "name": "app.dmg", "browser_download_url": "https://example.com/app.dmg" }
          ]
        }
        """.data(using: .utf8)!

        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        XCTAssertEqual(release.tagName, "v1.5.0")
        XCTAssertEqual(release.htmlUrl, "https://example.com/r")
        XCTAssertEqual(release.publishedAt, "2026-02-01T00:00:00Z")
        XCTAssertEqual(release.assets.count, 1)
        XCTAssertEqual(release.assets.first?.name, "app.dmg")
        XCTAssertEqual(release.assets.first?.browserDownloadUrl, "https://example.com/app.dmg")
    }

    // MARK: - Codable round-trip

    func testAppVersionCodableRoundTrip() throws {
        let original = AppVersion.mockUpdate
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppVersion.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
