import XCTest

@testable import speaktype

@MainActor
final class WhisperCppTuningTests: XCTestCase {

    private let keys = [
        WhisperCppTuning.Key.entropyThreshold,
        WhisperCppTuning.Key.temperatureIncrement,
        WhisperCppTuning.Key.carryContext,
    ]

    override func setUpWithError() throws {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        WhisperCppTuning.registerDefaults()
    }

    override func tearDownWithError() throws {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    func testDefaultsAreTheValidatedProductionValues() {
        XCTAssertEqual(WhisperCppTuning.entropyThreshold, 3.0, accuracy: 0.0001)
        XCTAssertEqual(WhisperCppTuning.temperatureIncrement, 0.2, accuracy: 0.0001)
        XCTAssertFalse(WhisperCppTuning.carryContext)
        XCTAssertTrue(WhisperCppTuning.isDefault)
    }

    /// The engine reuses one context across recordings, so `no_context` must be
    /// true by default or one dictation's tail bleeds into the next.
    func testNoContextIsTheInverseOfTheUserFacingToggle() {
        XCTAssertTrue(WhisperCppTuning.noContext, "carry-context off means no_context on")

        UserDefaults.standard.set(true, forKey: WhisperCppTuning.Key.carryContext)
        XCTAssertFalse(WhisperCppTuning.noContext)
    }

    func testValuesAreReadBackFromDefaults() {
        UserDefaults.standard.set(2.4, forKey: WhisperCppTuning.Key.entropyThreshold)
        UserDefaults.standard.set(0.4, forKey: WhisperCppTuning.Key.temperatureIncrement)

        XCTAssertEqual(WhisperCppTuning.entropyThreshold, 2.4, accuracy: 0.0001)
        XCTAssertEqual(WhisperCppTuning.temperatureIncrement, 0.4, accuracy: 0.0001)
        XCTAssertFalse(WhisperCppTuning.isDefault)
    }

    /// A hand-edited `defaults write` must not be able to wedge transcription.
    func testOutOfRangeValuesAreClamped() {
        UserDefaults.standard.set(99.0, forKey: WhisperCppTuning.Key.entropyThreshold)
        XCTAssertEqual(WhisperCppTuning.entropyThreshold, 6.0, accuracy: 0.0001)

        UserDefaults.standard.set(-5.0, forKey: WhisperCppTuning.Key.temperatureIncrement)
        XCTAssertEqual(WhisperCppTuning.temperatureIncrement, 0.0, accuracy: 0.0001)

        UserDefaults.standard.set(5.0, forKey: WhisperCppTuning.Key.temperatureIncrement)
        XCTAssertEqual(WhisperCppTuning.temperatureIncrement, 1.0, accuracy: 0.0001)
    }

    /// 0 is not "unset" — it disables the temperature fallback, which is a
    /// legitimate choice. Only a missing/zero entropy falls back to the default.
    func testZeroEntropyFallsBackButZeroTemperatureIsHonoured() {
        UserDefaults.standard.set(0.0, forKey: WhisperCppTuning.Key.entropyThreshold)
        XCTAssertEqual(WhisperCppTuning.entropyThreshold, 3.0, accuracy: 0.0001)

        UserDefaults.standard.set(0.0, forKey: WhisperCppTuning.Key.temperatureIncrement)
        XCTAssertEqual(WhisperCppTuning.temperatureIncrement, 0.0, accuracy: 0.0001)
    }

    func testResetRestoresDefaults() {
        UserDefaults.standard.set(5.0, forKey: WhisperCppTuning.Key.entropyThreshold)
        UserDefaults.standard.set(true, forKey: WhisperCppTuning.Key.carryContext)
        XCTAssertFalse(WhisperCppTuning.isDefault)

        WhisperCppTuning.resetToDefaults()

        XCTAssertTrue(WhisperCppTuning.isDefault)
        XCTAssertEqual(WhisperCppTuning.entropyThreshold, 3.0, accuracy: 0.0001)
        XCTAssertFalse(WhisperCppTuning.carryContext)
    }
}
