import XCTest

@testable import speaktype

final class SpokenLanguagePickerLogicTests: XCTestCase {
    func testFilteringMatchesCanonicalCodesAndNamesIgnoringCaseAndDiacritics() {
        XCTAssertEqual(
            SpokenLanguagePickerLogic.filteredLanguages(matching: "ZH").map(\.code),
            ["zh"])
        XCTAssertEqual(
            SpokenLanguagePickerLogic.filteredLanguages(matching: "hÍnDi").map(\.code),
            ["hi"])
    }

    func testCanonicalLanguageCatalogKeepsWhisperCodes() {
        XCTAssertEqual(SpokenLanguagePickerLogic.displayName(for: "es"), "Spanish")
        XCTAssertEqual(SpokenLanguagePickerLogic.displayName(for: "yue"), "Cantonese")
        XCTAssertEqual(SpokenLanguagePickerLogic.displayName(for: "auto"), "Auto-detect")
    }

    func testRecentsAreValidDeduplicatedAndRetainTheirOrder() {
        XCTAssertEqual(
            SpokenLanguagePickerLogic.recentLanguageCodes(
                from: "fr,es,fr,xx,auto,ja,it,de,pt,hi"),
            ["fr", "es", "ja", "it", "de"])
    }

    func testSelectingLanguageMovesItToFrontAndLimitsRecents() {
        XCTAssertEqual(
            SpokenLanguagePickerLogic.updatedRecentLanguages(
                selecting: "de", from: "fr,es,ja,it,pt"),
            "de,fr,es,ja,it")
        XCTAssertEqual(
            SpokenLanguagePickerLogic.updatedRecentLanguages(selecting: "auto", from: "fr,es"),
            "fr,es")
    }

    func testNoResultsAndAutoDetectFiltering() {
        XCTAssertTrue(SpokenLanguagePickerLogic.filteredLanguages(matching: "not-a-language").isEmpty)
        XCTAssertFalse(SpokenLanguagePickerLogic.matchesAutoDetect(query: "German"))
        XCTAssertTrue(SpokenLanguagePickerLogic.matchesAutoDetect(query: "dÉtect"))
        XCTAssertEqual(SpokenLanguagePickerLogic.filteredLanguages(matching: "  hÍnDi  ").map(\.code), ["hi"])
    }

    func testKeyboardOrderMatchesTheVisibleCurrentRecentAndAllLanguageRows() {
        let displayed = SpokenLanguagePickerLogic.displayedLanguageCodes(
            query: "",
            selectedCode: "en",
            recentCodes: ["fr", "es", "fr", "xx"])

        XCTAssertEqual(Array(displayed.prefix(5)), ["en", "fr", "es", "auto", "af"])
        XCTAssertEqual(Set(displayed).count, displayed.count)
    }

    func testKeyboardOrderMatchesSearchRows() {
        XCTAssertEqual(
            SpokenLanguagePickerLogic.displayedLanguageCodes(
                query: "  hÍnDi ", selectedCode: "en", recentCodes: ["fr"]),
            ["hi"])
    }
}
