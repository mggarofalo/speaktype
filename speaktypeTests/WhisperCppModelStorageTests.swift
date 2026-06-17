import XCTest

@testable import speaktype

@MainActor
final class WhisperCppModelStorageTests: XCTestCase {

    func testModelURLUsesExpectedGgmlFilenameForEachVariant() {
        let expected: [String: String] = [
            "openai_whisper-large-v3_turbo": "ggml-large-v3-turbo.bin",
            "openai_whisper-medium": "ggml-medium.bin",
            "openai_whisper-small.en": "ggml-small.en.bin",
            "openai_whisper-base.en": "ggml-base.en.bin",
            "openai_whisper-tiny": "ggml-tiny.bin",
        ]
        for (variant, filename) in expected {
            XCTAssertEqual(
                WhisperCppModelStorage.modelURL(for: variant)?.lastPathComponent, filename,
                "wrong GGML filename for \(variant)")
        }
    }

    func testDownloadURLPointsAtHuggingFaceGgmlWeights() {
        let url = WhisperCppModelStorage.downloadURL(for: "openai_whisper-large-v3_turbo")
        XCTAssertEqual(
            url?.absoluteString,
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")
    }

    func testUnknownVariantHasNoModelOrDownloadURL() {
        XCTAssertNil(WhisperCppModelStorage.modelURL(for: "not-a-real-variant"))
        XCTAssertNil(WhisperCppModelStorage.downloadURL(for: "not-a-real-variant"))
    }

    func testModelsDirIsUnderApplicationSupportSpeakType() {
        XCTAssertTrue(
            WhisperCppModelStorage.modelsDir.path.hasSuffix("SpeakType/whispercpp"),
            "GGML models should live under Application Support/SpeakType/whispercpp")
    }
}

@MainActor
final class TranscriptionEngineSelectionTests: XCTestCase {
    private let key = TranscriptionEngineSelection.defaultsKey

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: key)
    }

    func testResolvesExplicitlyStoredEngine() {
        UserDefaults.standard.set("whisperkit", forKey: key)
        XCTAssertEqual(TranscriptionEngineSelection.current, .whisperkit)
    }

    func testUnknownValueFallsBackToWhisperCpp() {
        UserDefaults.standard.set("nonsense", forKey: key)
        XCTAssertEqual(TranscriptionEngineSelection.current, .whispercpp)
    }

    func testDefaultKindIsWhisperCpp() {
        XCTAssertEqual(TranscriptionEngineSelection.defaultKind, .whispercpp)
    }
}
