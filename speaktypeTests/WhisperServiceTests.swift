import WhisperKit
import XCTest
@testable import speaktype

@MainActor
final class WhisperServiceTests: XCTestCase {
    
    var service: WhisperService?
    
    override func setUpWithError() throws {
        service = WhisperService()
    }

    override func tearDownWithError() throws {
        // Rely on automatic deallocation
    }

    func testDefaultInitialization() {
        guard let service = service else { return XCTFail("Service should be initialized") }
        XCTAssertFalse(service.isInitialized)
        XCTAssertEqual(service.currentModelVariant, "")
    }
    
    // Note: detailed loadModel tests require mocking the WhisperKit dependency
    // which is external. We test the state management around it.

    func testNormalizedTranscriptionRemovesBlankAudioPlaceholders() {
        let normalized = WhisperService.normalizedTranscription(
            from: " [BLANK_AUDIO]  hello   <|nospeech|> [SILENCE] "
        )

        XCTAssertEqual(normalized, "hello")
    }

    func testNormalizedTranscriptionRemovesBracketedNoiseLabels() {
        let normalized = WhisperService.normalizedTranscription(
            from: "[wind blowing] (heartbeat) answer [S]"
        )

        XCTAssertEqual(normalized, "answer")
    }

    func testNormalizedTranscriptionRemovesNoiseOnlyArtifacts() {
        let normalized = WhisperService.normalizedTranscription(
            from: "[wind] (Loud noise) (indistinct)"
        )

        XCTAssertEqual(normalized, "")
    }

    // MARK: - Decoding options

    func testDecodingOptionsWithoutPromptKeepsFirstTokenThreshold() {
        let options = WhisperService.decodingOptions(language: "auto", promptTokens: nil)

        XCTAssertNil(options.promptTokens)
        XCTAssertNotNil(options.firstTokenLogProbThreshold)
    }

    // Regression: with vocabulary prompt tokens present, WhisperKit's
    // firstTokenLogProbThreshold (-1.5 default) aborts every window with zero
    // tokens, so all dictations surfaced as "No speech detected". The
    // threshold must be disabled whenever a prompt conditions the decoder.
    func testDecodingOptionsWithPromptDisablesFirstTokenThreshold() {
        let options = WhisperService.decodingOptions(language: "auto", promptTokens: [1, 2, 3])

        XCTAssertEqual(options.promptTokens, [1, 2, 3])
        XCTAssertNil(options.firstTokenLogProbThreshold)
    }

    func testDecodingOptionsLanguageMapping() {
        XCTAssertNil(WhisperService.decodingOptions(language: "auto", promptTokens: nil).language)
        XCTAssertEqual(
            WhisperService.decodingOptions(language: "en", promptTokens: nil).language, "en")
    }

    // MARK: - Vocabulary prompt construction

    func testVocabularyPromptNilForEmptyOrBlankInput() {
        XCTAssertNil(WhisperService.vocabularyPrompt(from: ""))
        XCTAssertNil(WhisperService.vocabularyPrompt(from: " , \n , "))
    }

    func testVocabularyPromptJoinsCommaAndNewlineSeparatedTerms() {
        let prompt = WhisperService.vocabularyPrompt(from: "Jira, Blazor\n WhisperKit ")

        XCTAssertEqual(prompt, " Glossary: Jira, Blazor, WhisperKit.")
    }

    // MARK: - Filler-word removal
    //
    // All filler tests pass `removeFillerWords` explicitly so they never depend
    // on the shared `removeFillerWords` UserDefaults key.

    func testNormalizedTranscriptionRemovesBasicFillerVariants() {
        let normalized = WhisperService.normalizedTranscription(
            from: "So um the uh plan is erm ready hmm okay mhm",
            removeFillerWords: true
        )

        XCTAssertEqual(normalized, "So the plan is ready okay")
    }

    func testNormalizedTranscriptionRemovesElongatedFillers() {
        let normalized = WhisperService.normalizedTranscription(
            from: "Well umm I think uhhh we should go",
            removeFillerWords: true
        )

        XCTAssertEqual(normalized, "Well I think we should go")
    }

    func testNormalizedTranscriptionConsumesTrailingPunctuationAfterFiller() {
        let normalized = WhisperService.normalizedTranscription(
            from: "I went there, um, and then left",
            removeFillerWords: true
        )

        // The "um," (filler + trailing comma) is consumed; the comma after
        // "there" survives because it is not attached to a filler.
        XCTAssertEqual(normalized, "I went there, and then left")
    }

    func testNormalizedTranscriptionRemovesMultipleConsecutiveFillers() {
        let normalized = WhisperService.normalizedTranscription(
            from: "The answer is um uh erm fortytwo",
            removeFillerWords: true
        )

        XCTAssertEqual(normalized, "The answer is fortytwo")
    }

    func testNormalizedTranscriptionCollapsesStrandedCommaFromLeadingFiller() {
        // A filler at sentence start with a trailing comma would leave a
        // stranded " ," artifact after removal; it must collapse away.
        let normalized = WhisperService.normalizedTranscription(
            from: "Um, let me think",
            removeFillerWords: true
        )

        XCTAssertEqual(normalized, "let me think")
    }

    func testNormalizedTranscriptionPreservesFillersWhenDisabled() {
        let normalized = WhisperService.normalizedTranscription(
            from: "So um the uh plan is ready",
            removeFillerWords: false
        )

        XCTAssertEqual(normalized, "So um the uh plan is ready")
    }

    func testNormalizedTranscriptionDoesNotTouchWordsContainingFillerSubstrings() {
        // Word-boundary safety: these words embed um/uh/etc. and must survive.
        let normalized = WhisperService.normalizedTranscription(
            from: "Go ahead under the umbrella this summer",
            removeFillerWords: true
        )

        XCTAssertEqual(normalized, "Go ahead under the umbrella this summer")
    }
}
