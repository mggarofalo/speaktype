import XCTest
@testable import speaktype

final class AppVersionTests: XCTestCase {
    func testSemanticVersionOrdersMajorMinorAndPatchNumerically() {
        XCTAssertTrue(AppVersion.isNewerVersion("2.0.0", than: "1.99.99"))
        XCTAssertTrue(AppVersion.isNewerVersion("1.10.0", than: "1.9.9"))
        XCTAssertTrue(AppVersion.isNewerVersion("1.2.4", than: "1.2.3"))
        XCTAssertFalse(AppVersion.isNewerVersion("1.2.3", than: "1.2.3"))
    }

    func testSemanticVersionSupportsArbitrarilyLargeNumericComponents() {
        XCTAssertTrue(
            AppVersion.isNewerVersion(
                "999999999999999999999999.0.0",
                than: "999999999999999999999998.999.999"
            ))
    }

    func testSemanticVersionUsesPrereleasePrecedence() {
        let ordered = [
            "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
            "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0",
        ]

        for pair in zip(ordered.dropFirst(), ordered) {
            XCTAssertTrue(AppVersion.isNewerVersion(pair.0, than: pair.1))
        }
    }

    func testBuildMetadataDoesNotAffectPrecedence() {
        XCTAssertFalse(AppVersion.isNewerVersion("1.0.0+two", than: "1.0.0+one"))
        XCTAssertFalse(AppVersion.isNewerVersion("1.0.0+one", than: "1.0.0+two"))
    }

    func testInvalidSemanticVersionsAreNeverNewer() {
        XCTAssertFalse(AppVersion.isNewerVersion("1.2", than: "1.1.0"))
        XCTAssertFalse(AppVersion.isNewerVersion("01.2.3", than: "1.2.2"))
        XCTAssertFalse(AppVersion.isNewerVersion("1.2.3-01", than: "1.2.2"))
        XCTAssertFalse(AppVersion.isNewerVersion("latest", than: "1.2.2"))
    }

    func testAppVersionAcceptsStableVersionTagAndBuildsFirstPartyHTTPSURL() {
        let version = AppVersion(tagName: "v1.2.3")

        XCTAssertEqual(version?.version, "1.2.3")
        XCTAssertEqual(version?.tagName, "v1.2.3")
        XCTAssertEqual(
            version?.sourceURL.absoluteString,
            "https://github.com/mggarofalo/speaktype/tree/v1.2.3"
        )
        XCTAssertEqual(version?.sourceURL.scheme, "https")
        XCTAssertEqual(version?.sourceURL.host, "github.com")
    }

    func testAppVersionRejectsPrereleaseAndNonVersionTags() {
        XCTAssertNil(AppVersion(tagName: "v2.0.0-beta.1"))
        XCTAssertNil(AppVersion(tagName: "nightly"))
        XCTAssertNil(AppVersion(tagName: "v1.2.3/../../elsewhere"))
        XCTAssertNil(AppVersion(tagName: "https://example.com/v1.2.3"))
    }

    func testLatestStableFiltersJunkAndPrereleasesAndIgnoresAPIOrder() {
        let latest = AppVersion.latestStable(from: [
            GitHubTag(name: "v1.9.9"),
            GitHubTag(name: "nightly"),
            GitHubTag(name: "v2.0.0-beta.1"),
            GitHubTag(name: "v1.10.0"),
            GitHubTag(name: "v1.8.20"),
        ])

        XCTAssertEqual(latest?.version, "1.10.0")
        XCTAssertEqual(latest?.tagName, "v1.10.0")
    }

    func testLatestStableReturnsNilWithoutStableSemanticVersionTag() {
        XCTAssertNil(AppVersion.latestStable(from: [
            GitHubTag(name: "latest"),
            GitHubTag(name: "v2.0.0-rc.1"),
        ]))
    }

    func testGitHubTagDecodesOnlyNameFromFullResponseObject() throws {
        let data = #"{"name":"v1.5.0","zipball_url":"https://api.github.com/archive.zip","commit":{"sha":"abc"}}"#
            .data(using: .utf8)!

        let tag = try JSONDecoder().decode(GitHubTag.self, from: data)

        XCTAssertEqual(tag, GitHubTag(name: "v1.5.0"))
    }
}
