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
    
    func testStateFlags() {
        guard let service = service else { return XCTFail("Service should be initialized") }
        XCTAssertFalse(service.isTranscribing)
        // Simulate transcription start
        service.isTranscribing = true
        XCTAssertTrue(service.isTranscribing)
    }

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
}
