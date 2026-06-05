import Combine
import XCTest
@testable import speaktype

/// Fake release fetcher: returns a canned release or throws a canned error so
/// the update-decision flow runs without network access.
final class FakeReleaseFetcher: ReleaseFetching {
    enum FetchError: Error { case boom }

    var result: Result<GitHubRelease, Error>

    init(result: Result<GitHubRelease, Error>) {
        self.result = result
    }

    func fetchLatestRelease() async throws -> GitHubRelease {
        try result.get()
    }
}

@MainActor
final class UpdateServiceTests: XCTestCase {

    private let skippedVersionKey = "skippedVersion"
    private let lastCheckDateKey = "lastUpdateCheckDate"
    private let lastReminderDateKey = "lastUpdateReminderDate"

    // UserDefaults is shared process state; save and restore the keys this
    // suite touches so tests stay independent and order-insensitive.
    private var savedSkipped: Any?
    private var savedLastCheck: Any?
    private var savedReminder: Any?

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        savedSkipped = defaults.object(forKey: skippedVersionKey)
        savedLastCheck = defaults.object(forKey: lastCheckDateKey)
        savedReminder = defaults.object(forKey: lastReminderDateKey)
        defaults.removeObject(forKey: skippedVersionKey)
        defaults.removeObject(forKey: lastCheckDateKey)
        defaults.removeObject(forKey: lastReminderDateKey)
    }

    override func tearDown() {
        restore(savedSkipped, forKey: skippedVersionKey)
        restore(savedLastCheck, forKey: lastCheckDateKey)
        restore(savedReminder, forKey: lastReminderDateKey)
        super.tearDown()
    }

    private func restore(_ value: Any?, forKey key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    private func makeVersion(_ v: String, downloadURL: String = "https://example.com/app.dmg")
        -> AppVersion
    {
        AppVersion(
            version: v, buildNumber: "0", releaseNotes: [], downloadURL: downloadURL,
            isRequired: false, releaseDate: Date())
    }

    // MARK: - decideUpdate (pure)

    /// Assert the decision surfaced a version with the expected version string.
    /// `AppVersion` equality includes `releaseDate`, which differs by sub-second
    /// between the input and any freshly-built expectation, so compare the
    /// surfaced version itself rather than reconstructing an equal value.
    private func assertSurfaces(_ decision: UpdateService.UpdateDecision, version: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        guard case .surface(let surfaced) = decision else {
            XCTFail("expected .surface(\(version)), got \(decision)", file: file, line: line)
            return
        }
        XCTAssertEqual(surfaced.version, version, file: file, line: line)
    }

    func testDecideUpdateSurfacesNewerVersion() {
        let decision = UpdateService.decideUpdate(
            releaseVersion: makeVersion("2.0.0"),
            currentVersion: "1.0.0",
            skippedVersion: nil,
            silent: false)
        assertSurfaces(decision, version: "2.0.0")
    }

    func testDecideUpdateNoneForEqualVersion() {
        let decision = UpdateService.decideUpdate(
            releaseVersion: makeVersion("1.0.0"),
            currentVersion: "1.0.0",
            skippedVersion: nil,
            silent: false)
        XCTAssertEqual(decision, .none)
    }

    func testDecideUpdateNoneForOlderVersion() {
        let decision = UpdateService.decideUpdate(
            releaseVersion: makeVersion("0.9.0"),
            currentVersion: "1.0.0",
            skippedVersion: nil,
            silent: false)
        XCTAssertEqual(decision, .none)
    }

    func testDecideUpdateSilentCheckRespectsSkippedVersion() {
        let decision = UpdateService.decideUpdate(
            releaseVersion: makeVersion("2.0.0"),
            currentVersion: "1.0.0",
            skippedVersion: "2.0.0",
            silent: true)
        XCTAssertEqual(decision, .none,
                       "a silent check must not surface a version the user skipped")
    }

    func testDecideUpdateExplicitCheckSurfacesEvenWhenSkipped() {
        // skip-then-newer-still-surfaces on an explicit (user-initiated) check.
        let decision = UpdateService.decideUpdate(
            releaseVersion: makeVersion("2.0.0"),
            currentVersion: "1.0.0",
            skippedVersion: "2.0.0",
            silent: false)
        // skip-then-newer-still-surfaces on an explicit (user-initiated) check.
        assertSurfaces(decision, version: "2.0.0")
    }

    func testDecideUpdateSilentCheckSurfacesDifferentNewerVersionThanSkipped() {
        // User skipped 2.0.0, but 2.1.0 is out — a silent check should still surface it.
        let decision = UpdateService.decideUpdate(
            releaseVersion: makeVersion("2.1.0"),
            currentVersion: "1.0.0",
            skippedVersion: "2.0.0",
            silent: true)
        assertSurfaces(decision, version: "2.1.0")
    }

    // MARK: - checkForUpdates flow (via injected fetcher)

    private func release(tag: String) -> GitHubRelease {
        GitHubRelease(
            tagName: tag, body: "notes", htmlUrl: "https://example.com/r",
            publishedAt: "2026-01-01T00:00:00Z",
            assets: [GitHubAsset(name: "app.dmg", browserDownloadUrl: "https://example.com/app.dmg")])
    }

    func testCheckForUpdatesSetsLastCheckDateOnSuccess() async {
        let fetcher = FakeReleaseFetcher(result: .success(release(tag: "0.0.1")))
        let service = UpdateService(releaseFetcher: fetcher)
        XCTAssertNil(service.lastCheckDate)

        await service.checkForUpdates(silent: true)

        XCTAssertNotNil(service.lastCheckDate, "a successful check stamps lastCheckDate")
        XCTAssertFalse(service.isCheckingForUpdates)
    }

    func testCheckForUpdatesNoUpdateForOlderRelease() async {
        // currentVersion comes from the bundle ("1.0" in tests); 0.0.1 is older.
        let fetcher = FakeReleaseFetcher(result: .success(release(tag: "0.0.1")))
        let service = UpdateService(releaseFetcher: fetcher)

        await service.checkForUpdates(silent: false)

        XCTAssertNil(service.availableUpdate,
                     "an older release must not produce an available update")
    }

    func testCheckForUpdatesSurfacesNewerRelease() async {
        let fetcher = FakeReleaseFetcher(result: .success(release(tag: "999.0.0")))
        let service = UpdateService(releaseFetcher: fetcher)

        await service.checkForUpdates(silent: false)

        XCTAssertEqual(service.availableUpdate?.version, "999.0.0",
                       "a clearly-newer release surfaces as an available update")
    }

    func testCheckForUpdatesSilentRespectsSkippedVersion() async {
        UserDefaults.standard.set("999.0.0", forKey: skippedVersionKey)
        let fetcher = FakeReleaseFetcher(result: .success(release(tag: "999.0.0")))
        let service = UpdateService(releaseFetcher: fetcher)

        await service.checkForUpdates(silent: true)

        XCTAssertNil(service.availableUpdate,
                     "a silent check must not surface a skipped version")
    }

    func testCheckForUpdatesFailedFetchLeavesNoUpdateAndDoesNotCrash() async {
        let fetcher = FakeReleaseFetcher(result: .failure(FakeReleaseFetcher.FetchError.boom))
        let service = UpdateService(releaseFetcher: fetcher)

        await service.checkForUpdates(silent: false)

        XCTAssertNil(service.availableUpdate, "a failed fetch must not assert a false update")
        XCTAssertFalse(service.isCheckingForUpdates, "the checking flag must be reset on failure")
        XCTAssertNil(service.lastCheckDate, "a failed check must not stamp lastCheckDate")
    }

    func testCheckForUpdatesIgnoredWhileAlreadyChecking() async {
        let fetcher = FakeReleaseFetcher(result: .success(release(tag: "999.0.0")))
        let service = UpdateService(releaseFetcher: fetcher)
        service.isCheckingForUpdates = true

        await service.checkForUpdates(silent: false)

        // Guard returns early; availableUpdate stays untouched (nil) and the
        // pre-set flag is left as-is.
        XCTAssertNil(service.availableUpdate)
        XCTAssertTrue(service.isCheckingForUpdates)
    }

    func testCheckForUpdatesPublishesNewerReleaseToWindowPublisher() async {
        let fetcher = FakeReleaseFetcher(result: .success(release(tag: "999.0.0")))
        let service = UpdateService(releaseFetcher: fetcher)

        let expectation = expectation(description: "window publisher fires")
        var cancellables = Set<AnyCancellable>()
        service.showUpdateWindowPublisher
            .sink { version in
                XCTAssertEqual(version.version, "999.0.0")
                expectation.fulfill()
            }
            .store(in: &cancellables)

        await service.checkForUpdates(silent: false)
        await fulfillment(of: [expectation], timeout: 1)
    }

    // MARK: - Skip-version persistence

    func testSkipVersionPersistsAndClearsAvailableUpdate() {
        let service = UpdateService(
            releaseFetcher: FakeReleaseFetcher(result: .success(release(tag: "0.0.1"))))
        service.availableUpdate = makeVersion("2.0.0")

        service.skipVersion("2.0.0")

        XCTAssertEqual(UserDefaults.standard.string(forKey: skippedVersionKey), "2.0.0")
        XCTAssertNil(service.availableUpdate,
                     "skipping the surfaced update must clear it from state")
    }

    func testClearSkippedVersionRemovesPersistedKey() {
        UserDefaults.standard.set("2.0.0", forKey: skippedVersionKey)
        let service = UpdateService(
            releaseFetcher: FakeReleaseFetcher(result: .success(release(tag: "0.0.1"))))

        service.clearSkippedVersion()

        XCTAssertNil(UserDefaults.standard.string(forKey: skippedVersionKey))
    }

    // MARK: - shouldCheckForUpdates bookkeeping

    func testShouldCheckForUpdatesTrueWhenNeverChecked() {
        let service = UpdateService(
            releaseFetcher: FakeReleaseFetcher(result: .success(release(tag: "0.0.1"))))
        service.lastCheckDate = nil
        XCTAssertTrue(service.shouldCheckForUpdates())
    }

    func testShouldCheckForUpdatesFalseWithinTwentyFourHours() {
        let service = UpdateService(
            releaseFetcher: FakeReleaseFetcher(result: .success(release(tag: "0.0.1"))))
        service.lastCheckDate = Date().addingTimeInterval(-3600)  // 1 hour ago
        XCTAssertFalse(service.shouldCheckForUpdates())
    }

    func testShouldCheckForUpdatesTrueAfterTwentyFourHours() {
        let service = UpdateService(
            releaseFetcher: FakeReleaseFetcher(result: .success(release(tag: "0.0.1"))))
        service.lastCheckDate = Date().addingTimeInterval(-25 * 3600)  // 25 hours ago
        XCTAssertTrue(service.shouldCheckForUpdates())
    }

    // MARK: - shouldShowReminder bookkeeping

    func testShouldShowReminderFalseWhenNoAvailableUpdate() {
        let service = UpdateService(
            releaseFetcher: FakeReleaseFetcher(result: .success(release(tag: "0.0.1"))))
        service.availableUpdate = nil
        XCTAssertFalse(service.shouldShowReminder(),
                       "no reminder when there is no update to remind about")
    }

    func testShouldShowReminderTrueWhenUpdateAvailableAndNeverReminded() {
        let service = UpdateService(
            releaseFetcher: FakeReleaseFetcher(result: .success(release(tag: "0.0.1"))))
        service.availableUpdate = makeVersion("2.0.0")
        XCTAssertTrue(service.shouldShowReminder())
    }

    func testShouldShowReminderFalseWithinTwentyFourHoursOfLastReminder() {
        UserDefaults.standard.set(Date().addingTimeInterval(-3600), forKey: lastReminderDateKey)
        let service = UpdateService(
            releaseFetcher: FakeReleaseFetcher(result: .success(release(tag: "0.0.1"))))
        service.availableUpdate = makeVersion("2.0.0")
        XCTAssertFalse(service.shouldShowReminder())
    }

    func testMarkReminderShownPersistsTimestamp() {
        let service = UpdateService(
            releaseFetcher: FakeReleaseFetcher(result: .success(release(tag: "0.0.1"))))
        XCTAssertNil(UserDefaults.standard.object(forKey: lastReminderDateKey))

        service.markReminderShown()

        XCTAssertNotNil(UserDefaults.standard.object(forKey: lastReminderDateKey) as? Date)
    }
}
