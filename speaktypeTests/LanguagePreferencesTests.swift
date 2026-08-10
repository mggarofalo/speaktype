import XCTest

@testable import speaktype

@MainActor
final class LanguagePreferencesTests: XCTestCase {

    private let multilingual = "openai_whisper-large-v3_turbo"
    private let englishOnly = "openai_whisper-base.en"

    override func setUpWithError() throws {
        UserDefaults.standard.removeObject(forKey: LanguagePreferences.mapKey)
        UserDefaults.standard.removeObject(forKey: LanguagePreferences.globalKey)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: LanguagePreferences.mapKey)
        UserDefaults.standard.removeObject(forKey: LanguagePreferences.globalKey)
    }

    // MARK: - Per-model memory

    func testUnsetModelFallsBackToTheGlobalLanguage() {
        UserDefaults.standard.set("fr", forKey: LanguagePreferences.globalKey)
        XCTAssertEqual(LanguagePreferences.storedLanguage(forModel: multilingual), "fr")
    }

    func testGlobalDefaultsToAutoWhenNothingIsSet() {
        XCTAssertEqual(LanguagePreferences.storedLanguage(forModel: multilingual), "auto")
    }

    /// The regression this exists for: picking a language on one model used to
    /// clobber every other model's choice.
    func testEachModelRemembersItsOwnLanguage() {
        LanguagePreferences.setLanguage("es", forModel: multilingual)
        LanguagePreferences.setLanguage("de", forModel: "openai_whisper-medium")

        XCTAssertEqual(LanguagePreferences.storedLanguage(forModel: multilingual), "es")
        XCTAssertEqual(
            LanguagePreferences.storedLanguage(forModel: "openai_whisper-medium"), "de")
    }

    func testSettingALanguageAlsoUpdatesTheGlobalFallback() {
        LanguagePreferences.setLanguage("ja", forModel: multilingual)
        XCTAssertEqual(LanguagePreferences.globalLanguage, "ja")
        // A model never set explicitly inherits it.
        XCTAssertEqual(LanguagePreferences.storedLanguage(forModel: "openai_whisper-tiny"), "ja")
    }

    func testSwitchingAwayAndBackKeepsTheOriginalChoice() {
        LanguagePreferences.setLanguage("es", forModel: multilingual)
        LanguagePreferences.setLanguage("auto", forModel: "openai_whisper-tiny")
        XCTAssertEqual(LanguagePreferences.storedLanguage(forModel: multilingual), "es")
    }

    func testAnEmptyVariantDoesNotCreateAMapEntry() {
        LanguagePreferences.setLanguage("it", forModel: "")
        XCTAssertEqual(LanguagePreferences.globalLanguage, "it")
        XCTAssertEqual(LanguagePreferences.storedLanguage(forModel: ""), "it")
    }

    // MARK: - English-only models

    func testEnglishOnlyModelsAreDetected() {
        XCTAssertTrue(LanguagePreferences.isEnglishOnly(englishOnly))
        XCTAssertFalse(LanguagePreferences.isEnglishOnly(multilingual))
        XCTAssertFalse(LanguagePreferences.isEnglishOnly("not-a-model"))
    }

    /// whisper.cpp emits English from a .en model whatever is requested, so
    /// asking it to auto-detect first is a pass that cannot change the outcome.
    func testEnglishOnlyModelResolvesToEnglishRatherThanAuto() {
        LanguagePreferences.setLanguage("auto", forModel: englishOnly)
        XCTAssertEqual(LanguagePreferences.effectiveLanguage(forModel: englishOnly), "en")
    }

    func testEnglishOnlyModelIgnoresAStoredNonEnglishLanguage() {
        UserDefaults.standard.set("es", forKey: LanguagePreferences.globalKey)
        XCTAssertEqual(LanguagePreferences.effectiveLanguage(forModel: englishOnly), "en")
    }

    func testMultilingualModelPassesTheSelectionThrough() {
        LanguagePreferences.setLanguage("es", forModel: multilingual)
        XCTAssertEqual(LanguagePreferences.effectiveLanguage(forModel: multilingual), "es")
    }

    func testMultilingualModelKeepsAutoSoDetectionRuns() {
        LanguagePreferences.setLanguage("auto", forModel: multilingual)
        XCTAssertEqual(LanguagePreferences.effectiveLanguage(forModel: multilingual), "auto")
    }

    // MARK: - Display

    func testDisplayNameMapsCodesAndFallsBackToTheRawCode() {
        XCTAssertEqual(LanguagePreferences.displayName(for: "auto"), "Auto-detect")
        XCTAssertEqual(LanguagePreferences.displayName(for: "es"), "Spanish")
        XCTAssertEqual(LanguagePreferences.displayName(for: "zz"), "zz")
    }
}
