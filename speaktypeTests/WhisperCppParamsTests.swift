import WhisperCPP
import XCTest

@testable import speaktype

/// Guards the whisper.cpp decode parameters against a regression that silently
/// broke every dictation on the default language setting.
final class WhisperCppParamsTests: XCTestCase {

    private func params(
        noContext: Bool = false, entropyThreshold: Float = 3.0, temperatureIncrement: Float = 0.2
    ) -> whisper_full_params {
        WhisperCPPContext.makeParams(
            threads: 4, noContext: noContext, entropyThreshold: entropyThreshold,
            temperatureIncrement: temperatureIncrement)
    }

    /// `detect_language` means "detect the language and then stop" —
    /// `whisper_full` returns 0 having emitted zero segments. It was being set
    /// whenever the language was nil (i.e. the default "Auto" setting), so every
    /// auto-language dictation transcribed to "" and surfaced as "No speech
    /// detected". Auto-detect is requested by leaving `params.language` nil.
    func testDetectLanguageIsNeverSet() {
        XCTAssertFalse(
            params().detect_language,
            "detect_language makes whisper_full return zero segments — auto-language dictation would come back empty")
    }

    /// whisper.cpp's own default is "en", not nil — `transcribe` always
    /// overwrites it with the caller's language, passing nil to request
    /// auto-detect. Pinned so the "en" baked into `whisper_full_default_params`
    /// is not mistaken for the effective setting.
    func testWhisperDefaultLanguageIsEnglishAndIsOverriddenPerCall() {
        XCTAssertEqual(
            params().language.map { String(cString: $0) }, "en",
            "whisper.cpp's default; transcribe() replaces it per call (nil = auto-detect)")
    }

    func testLoopResistanceValuesArePassedThrough() {
        // entropyThreshold 3.0 is the validated production value that contains
        // the repetition loop; make sure the seam actually forwards it.
        let p = params(entropyThreshold: 3.0, temperatureIncrement: 0.2)
        XCTAssertEqual(p.entropy_thold, 3.0, accuracy: 0.0001)
        XCTAssertEqual(p.temperature_inc, 0.2, accuracy: 0.0001)
    }

    func testNoContextIsForwarded() {
        XCTAssertTrue(params(noContext: true).no_context)
        XCTAssertFalse(params(noContext: false).no_context)
    }

    func testPrintingIsDisabledSoTheCLIDoesNotWriteToStdout() {
        let p = params()
        XCTAssertFalse(p.print_realtime)
        XCTAssertFalse(p.print_progress)
        XCTAssertFalse(p.print_timestamps)
    }
}
