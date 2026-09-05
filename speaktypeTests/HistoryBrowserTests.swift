import XCTest
@testable import speaktype

@MainActor
final class HistoryBrowserTests: XCTestCase {
    private var service: HistoryService!
    private var databaseURL: URL!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!

    override func setUp() {
        super.setUp()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryBrowserTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("history.sqlite")
        defaultsSuiteName = "HistoryBrowserTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        service = HistoryService(databaseURL: databaseURL, defaults: defaults)
    }

    override func tearDown() async throws {
        await service.flush()
        let directory = databaseURL.deletingLastPathComponent()
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: directory)
        service = nil
        defaults = nil
        defaultsSuiteName = nil
        try await super.tearDown()
    }

    func testPagesAreBoundedToFiftyAndNavigate() async {
        for index in 0..<51 {
            service.addItem(transcript: "Entry \(index)", duration: 1)
        }
        await service.flush()

        let browser = HistoryBrowser(historyService: service)
        await browser.loadInitialPage()
        XCTAssertEqual(browser.rows.count, 50)
        XCTAssertEqual(browser.totalCount, 51)
        XCTAssertFalse(browser.canGoBack)
        XCTAssertTrue(browser.canGoForward)

        await browser.nextPage()
        XCTAssertEqual(browser.offset, 50)
        XCTAssertEqual(browser.rows.count, 1)
        XCTAssertTrue(browser.canGoBack)
        XCTAssertFalse(browser.canGoForward)
    }

    func testSearchResetsToFirstPageAndUsesFetchedPresentationData() async {
        for index in 0..<51 {
            service.addItem(transcript: "General entry \(index)", duration: 1)
        }
        service.addItem(transcript: "needle has three words", duration: 1)
        await service.flush()

        let browser = HistoryBrowser(historyService: service)
        await browser.loadInitialPage()
        await browser.nextPage()
        browser.searchText = "needle"
        await browser.search()

        XCTAssertEqual(browser.offset, 0)
        XCTAssertEqual(browser.totalCount, 1)
        XCTAssertEqual(browser.rows.count, 1)
        XCTAssertEqual(browser.rows[0].wordCount, 4)
        XCTAssertEqual(browser.rows[0].preview, "needle has three words")
    }

    func testRefreshReturnsToLastValidPageAfterDeletion() async throws {
        for index in 0..<51 {
            service.addItem(transcript: "Entry \(index)", duration: 1)
        }
        await service.flush()

        let browser = HistoryBrowser(historyService: service)
        await browser.loadInitialPage()
        await browser.nextPage()
        let finalItemID = try XCTUnwrap(browser.rows.first?.id)

        service.deleteItem(id: finalItemID)
        await service.flush()
        await browser.refresh()

        XCTAssertEqual(browser.totalCount, 50)
        XCTAssertEqual(browser.offset, 0)
        XCTAssertEqual(browser.rows.count, 50)
    }
}
