import Combine
import XCTest
@testable import speaktype

@MainActor
private final class FakeTagFetcher: TagFetching {
    enum FetchError: Error { case failed }

    private let handler: (Int, Int) throws -> [GitHubTag]
    private(set) var requestedPages: [Int] = []
    private(set) var requestedPageSizes: [Int] = []

    init(handler: @escaping (Int, Int) throws -> [GitHubTag]) {
        self.handler = handler
    }

    convenience init(tags: [GitHubTag]) {
        self.init { page, _ in page == 1 ? tags : [] }
    }

    func fetchTags(page: Int, perPage: Int) async throws -> [GitHubTag] {
        requestedPages.append(page)
        requestedPageSizes.append(perPage)
        return try handler(page, perPage)
    }
}

@MainActor
final class UpdateServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "UpdateServiceTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
        super.tearDown()
    }

    private func makeService(
        fetcher: FakeTagFetcher,
        currentVersion: String = "1.0.0",
        now: Date? = nil
    ) -> UpdateService {
        let checkDate = now ?? fixedNow
        return UpdateService(
            tagFetcher: fetcher,
            defaults: defaults,
            currentVersion: { currentVersion },
            now: { checkDate }
        )
    }

    private func version(_ tag: String) -> AppVersion {
        AppVersion(tagName: tag)!
    }

    // MARK: - Update decisions

    func testDecideUpdateSurfacesNewerVersion() {
        let decision = UpdateService.decideUpdate(
            releaseVersion: version("v2.0.0"),
            currentVersion: "1.0.0",
            skippedVersion: nil,
            silent: false
        )

        guard case .surface(let surfaced) = decision else {
            return XCTFail("Expected newer version to surface")
        }
        XCTAssertEqual(surfaced.version, "2.0.0")
    }

    func testDecideUpdateRejectsEqualAndOlderVersions() {
        XCTAssertEqual(
            UpdateService.decideUpdate(
                releaseVersion: version("v1.0.0"), currentVersion: "1.0.0",
                skippedVersion: nil, silent: false),
            .none
        )
        XCTAssertEqual(
            UpdateService.decideUpdate(
                releaseVersion: version("v0.9.0"), currentVersion: "1.0.0",
                skippedVersion: nil, silent: false),
            .none
        )
    }

    func testSilentCheckSuppressesSkippedVersionButManualCheckSurfacesIt() {
        let available = version("v2.0.0")
        XCTAssertEqual(
            UpdateService.decideUpdate(
                releaseVersion: available, currentVersion: "1.0.0",
                skippedVersion: "2.0.0", silent: true),
            .none
        )

        guard case .surface = UpdateService.decideUpdate(
            releaseVersion: available, currentVersion: "1.0.0",
            skippedVersion: "2.0.0", silent: false
        ) else {
            return XCTFail("A user-initiated check should show a skipped version")
        }
    }

    func testSilentCheckSurfacesVersionNewerThanSkippedVersion() {
        guard case .surface(let surfaced) = UpdateService.decideUpdate(
            releaseVersion: version("v2.1.0"),
            currentVersion: "1.0.0",
            skippedVersion: "2.0.0",
            silent: true
        ) else {
            return XCTFail("A later tag should supersede the skipped version")
        }

        XCTAssertEqual(surfaced.version, "2.1.0")
    }

    // MARK: - Manual status and notification flow

    func testManualCheckSurfacesLatestStableTagAndReportsAvailableStatus() async {
        let fetcher = FakeTagFetcher(tags: [
            GitHubTag(name: "v1.5.0"),
            GitHubTag(name: "v3.0.0-beta.1"),
            GitHubTag(name: "v2.0.0"),
        ])
        let service = makeService(fetcher: fetcher)
        var surfacedVersions: [String] = []
        let cancellable = service.showUpdateWindowPublisher
            .sink { surfacedVersions.append($0.version) }

        await service.checkForUpdates()

        XCTAssertEqual(service.availableUpdate?.version, "2.0.0")
        XCTAssertEqual(service.checkStatus, .updateAvailable(version: "2.0.0"))
        XCTAssertEqual(surfacedVersions, ["2.0.0"])
        XCTAssertEqual(service.lastCheckDate, fixedNow)
        XCTAssertFalse(service.isCheckingForUpdates)
        withExtendedLifetime(cancellable) {}
    }

    func testManualCheckReportsUpToDate() async {
        let service = makeService(
            fetcher: FakeTagFetcher(tags: [GitHubTag(name: "v1.0.0")])
        )

        await service.checkForUpdates()

        XCTAssertNil(service.availableUpdate)
        XCTAssertEqual(service.checkStatus, .upToDate(version: "1.0.0"))
        XCTAssertEqual(service.checkStatus?.message, "SpeakType 1.0.0 is up to date.")
        XCTAssertFalse(service.checkStatus?.isError ?? true)
    }

    func testManualCheckWithoutStableTagsReportsFailureAndDoesNotStampSuccess() async {
        let service = makeService(fetcher: FakeTagFetcher(tags: [
            GitHubTag(name: "nightly"),
            GitHubTag(name: "v2.0.0-beta.1"),
        ]))

        await service.checkForUpdates()

        XCTAssertEqual(service.checkStatus, .failed)
        XCTAssertTrue(service.checkStatus?.isError ?? false)
        XCTAssertNil(service.lastCheckDate)
        XCTAssertNil(defaults.object(forKey: "lastUpdateCheckDate"))
    }

    func testManualFetchFailureReportsFailureAndPreservesKnownUpdate() async {
        let fetcher = FakeTagFetcher { _, _ in throw FakeTagFetcher.FetchError.failed }
        let service = makeService(fetcher: fetcher)
        service.availableUpdate = version("v2.0.0")

        await service.checkForUpdates()

        XCTAssertEqual(service.checkStatus, .failed)
        XCTAssertEqual(service.availableUpdate?.version, "2.0.0")
        XCTAssertNil(service.lastCheckDate)
        XCTAssertFalse(service.isCheckingForUpdates)
    }

    func testSilentFailureDoesNotCreateVisibleManualStatus() async {
        let fetcher = FakeTagFetcher { _, _ in throw FakeTagFetcher.FetchError.failed }
        let service = makeService(fetcher: fetcher)

        await service.checkForUpdates(silent: true)

        XCTAssertNil(service.checkStatus)
    }

    // MARK: - Pagination policy

    func testCheckFetchesFullPagesUntilShortPageAndSortsAcrossPages() async {
        let fullFirstPage = [GitHubTag(name: "v1.1.0")]
            + Array(repeating: GitHubTag(name: "not-a-version"), count: 99)
        let fetcher = FakeTagFetcher { page, _ in
            switch page {
            case 1: return fullFirstPage
            case 2: return [GitHubTag(name: "v2.0.0"), GitHubTag(name: "v1.9.0")]
            default: return []
            }
        }
        let service = makeService(fetcher: fetcher)

        await service.checkForUpdates()

        XCTAssertEqual(fetcher.requestedPages, [1, 2])
        XCTAssertEqual(fetcher.requestedPageSizes, [100, 100])
        XCTAssertEqual(service.availableUpdate?.version, "2.0.0")
    }

    func testFullFinalAllowedPageFailsRatherThanClaimingFromTruncatedTags() async {
        let fetcher = FakeTagFetcher { _, _ in
            [GitHubTag(name: "v2.0.0")]
                + Array(repeating: GitHubTag(name: "not-a-version"), count: 99)
        }
        let service = makeService(fetcher: fetcher)

        await service.checkForUpdates()

        XCTAssertEqual(
            fetcher.requestedPages,
            Array(1...UpdateService.maximumTagPages)
        )
        XCTAssertEqual(service.checkStatus, .failed)
        XCTAssertNil(service.availableUpdate)
        XCTAssertNil(service.lastCheckDate)
    }

    // MARK: - Silent checks, skip and reminder preferences

    func testSilentCheckRespectsSkippedVersion() async {
        defaults.set("2.0.0", forKey: "skippedVersion")
        let service = makeService(
            fetcher: FakeTagFetcher(tags: [GitHubTag(name: "v2.0.0")])
        )
        var surfacedVersions: [String] = []
        let cancellable = service.showUpdateWindowPublisher
            .sink { surfacedVersions.append($0.version) }

        await service.checkForUpdates(silent: true)

        XCTAssertNil(service.availableUpdate)
        XCTAssertTrue(surfacedVersions.isEmpty)
        XCTAssertEqual(service.lastCheckDate, fixedNow)
        withExtendedLifetime(cancellable) {}
    }

    func testSilentCheckPublishesUpdateWhenReminderIsDue() async {
        let service = makeService(
            fetcher: FakeTagFetcher(tags: [GitHubTag(name: "v2.0.0")])
        )
        var surfacedVersions: [String] = []
        let cancellable = service.showUpdateWindowPublisher
            .sink { surfacedVersions.append($0.version) }

        await service.checkForUpdates(silent: true)

        XCTAssertEqual(surfacedVersions, ["2.0.0"])
        XCTAssertNil(service.checkStatus)
        withExtendedLifetime(cancellable) {}
    }

    func testSilentCheckDoesNotPublishUpdateWithinReminderInterval() async {
        defaults.set(fixedNow.addingTimeInterval(-60 * 60), forKey: "lastUpdateReminderDate")
        let service = makeService(
            fetcher: FakeTagFetcher(tags: [GitHubTag(name: "v2.0.0")])
        )
        var surfacedVersions: [String] = []
        let cancellable = service.showUpdateWindowPublisher
            .sink { surfacedVersions.append($0.version) }

        await service.checkForUpdates(silent: true)

        XCTAssertEqual(service.availableUpdate?.version, "2.0.0")
        XCTAssertTrue(surfacedVersions.isEmpty)
        withExtendedLifetime(cancellable) {}
    }

    func testSkipAndReminderUseInjectedDefaultsAndClock() {
        let service = makeService(
            fetcher: FakeTagFetcher(tags: [GitHubTag(name: "v2.0.0")])
        )
        service.availableUpdate = version("v2.0.0")

        service.markReminderShown()
        XCTAssertEqual(defaults.object(forKey: "lastUpdateReminderDate") as? Date, fixedNow)

        service.skipVersion("2.0.0")
        XCTAssertEqual(defaults.string(forKey: "skippedVersion"), "2.0.0")
        XCTAssertNil(service.availableUpdate)

        service.clearSkippedVersion()
        XCTAssertNil(defaults.string(forKey: "skippedVersion"))
    }

    // MARK: - Check cadence and opt-in preference

    func testCheckCadenceUsesInjectedClock() {
        let recent = makeService(
            fetcher: FakeTagFetcher(tags: []),
            now: fixedNow
        )
        recent.lastCheckDate = fixedNow.addingTimeInterval(-23 * 60 * 60)
        XCTAssertFalse(recent.shouldCheckForUpdates())

        recent.lastCheckDate = fixedNow.addingTimeInterval(-24 * 60 * 60)
        XCTAssertTrue(recent.shouldCheckForUpdates())
    }

    func testAutomaticChecksRequireExplicitOptIn() {
        let service = makeService(fetcher: FakeTagFetcher(tags: []))
        XCTAssertFalse(service.isAutomaticCheckEnabled)

        service.isAutomaticCheckEnabled = true

        XCTAssertTrue(defaults.bool(forKey: "autoUpdate"))
        XCTAssertTrue(service.isAutomaticCheckEnabled)
    }

    func testAlreadyRunningCheckDoesNotFetchAgain() async {
        let fetcher = FakeTagFetcher(tags: [GitHubTag(name: "v2.0.0")])
        let service = makeService(fetcher: fetcher)
        service.isCheckingForUpdates = true

        await service.checkForUpdates()

        XCTAssertTrue(fetcher.requestedPages.isEmpty)
        XCTAssertTrue(service.isCheckingForUpdates)
    }
}
