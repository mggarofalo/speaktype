import XCTest
@testable import speaktype

final class TranscriptionResultTests: XCTestCase {

    // MARK: - Initialization defaults

    func testInitAppliesDocumentedDefaults() {
        let result = TranscriptionResult(text: "hello", audioDuration: 3.0)
        XCTAssertEqual(result.text, "hello")
        XCTAssertEqual(result.audioDuration, 3.0)
        XCTAssertNil(result.confidence)
        XCTAssertEqual(result.language, "en")
        XCTAssertEqual(result.modelName, "base")
        XCTAssertFalse(result.isEdited)
        XCTAssertNil(result.error)
    }

    // MARK: - isSuccessful

    func testIsSuccessfulWhenTextPresentAndNoError() {
        let result = TranscriptionResult(text: "transcribed", audioDuration: 1.0)
        XCTAssertTrue(result.isSuccessful)
    }

    func testIsNotSuccessfulWhenTextEmpty() {
        let result = TranscriptionResult(text: "", audioDuration: 1.0)
        XCTAssertFalse(result.isSuccessful)
    }

    func testIsNotSuccessfulWhenErrorPresent() {
        // Even with text, a non-nil error means the result is not successful.
        let result = TranscriptionResult(text: "partial", audioDuration: 1.0, error: "boom")
        XCTAssertFalse(result.isSuccessful)
    }

    // MARK: - formattedDuration

    func testFormattedDurationUnderOneMinute() {
        let result = TranscriptionResult(text: "x", audioDuration: 5)
        XCTAssertEqual(result.formattedDuration, "0:05")
    }

    func testFormattedDurationOverOneMinute() {
        let result = TranscriptionResult(text: "x", audioDuration: 125)
        XCTAssertEqual(result.formattedDuration, "2:05")
    }

    func testFormattedDurationTruncatesFractionalSeconds() {
        let result = TranscriptionResult(text: "x", audioDuration: 59.9)
        XCTAssertEqual(result.formattedDuration, "0:59")
    }

    func testFormattedDurationZero() {
        let result = TranscriptionResult(text: "x", audioDuration: 0)
        XCTAssertEqual(result.formattedDuration, "0:00")
    }

    // MARK: - confidencePercentage

    func testConfidencePercentageNilWhenNoConfidence() {
        let result = TranscriptionResult(text: "x", audioDuration: 1, confidence: nil)
        XCTAssertNil(result.confidencePercentage)
    }

    func testConfidencePercentageFormatsToOneDecimal() {
        let result = TranscriptionResult(text: "x", audioDuration: 1, confidence: 0.876)
        XCTAssertEqual(result.confidencePercentage, "87.6%")
    }

    func testConfidencePercentageZero() {
        let result = TranscriptionResult(text: "x", audioDuration: 1, confidence: 0.0)
        XCTAssertEqual(result.confidencePercentage, "0.0%")
    }

    // MARK: - Equatable

    func testEqualResultsCompareEqual() {
        let id = UUID()
        let ts = Date(timeIntervalSince1970: 1000)
        let a = TranscriptionResult(id: id, text: "x", timestamp: ts, audioDuration: 1)
        let b = TranscriptionResult(id: id, text: "x", timestamp: ts, audioDuration: 1)
        XCTAssertEqual(a, b)
    }

    func testResultsWithDifferentTextAreNotEqual() {
        let id = UUID()
        let ts = Date(timeIntervalSince1970: 1000)
        let a = TranscriptionResult(id: id, text: "x", timestamp: ts, audioDuration: 1)
        let b = TranscriptionResult(id: id, text: "y", timestamp: ts, audioDuration: 1)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Codable round-trip

    func testCodableRoundTripPreservesAllFields() throws {
        let original = TranscriptionResult(
            id: UUID(),
            text: "round trip",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            audioDuration: 12.5,
            confidence: 0.42,
            language: "fr",
            modelName: "small",
            isEdited: true,
            error: "warn"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptionResult.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testCodableRoundTripWithNilOptionals() throws {
        let original = TranscriptionResult(text: "x", audioDuration: 1)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptionResult.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.confidence)
        XCTAssertNil(decoded.error)
    }

    // MARK: - Factory methods

    func testErrorFactoryProducesUnsuccessfulResult() {
        let result = TranscriptionResult.error(message: "failed", audioDuration: 4)
        XCTAssertEqual(result.error, "failed")
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.audioDuration, 4)
        XCTAssertFalse(result.isSuccessful)
    }

    func testErrorFactoryDefaultsDurationToZero() {
        let result = TranscriptionResult.error(message: "failed")
        XCTAssertEqual(result.audioDuration, 0)
    }

    func testEmptyFactoryIsNotSuccessful() {
        let result = TranscriptionResult.empty
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.audioDuration, 0)
        XCTAssertNil(result.error)
        XCTAssertFalse(result.isSuccessful)
    }
}
