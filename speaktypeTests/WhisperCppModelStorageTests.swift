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

    /// The scratch file a resumable download appends to. Cancellation deletes it
    /// via `delete(variant:)`; previously it was derived inline and leaked.
    func testPartialURLSitsBesideTheModelWithPartialExtension() {
        for variant in ["openai_whisper-tiny", "openai_whisper-base.en"] {
            let model = WhisperCppModelStorage.modelURL(for: variant)
            let partial = WhisperCppModelStorage.partialURL(for: variant)
            XCTAssertEqual(partial?.path, model.map { $0.path + ".partial" })
        }
    }

    func testUnknownVariantHasNoPartialURL() {
        XCTAssertNil(WhisperCppModelStorage.partialURL(for: "not-a-real-variant"))
    }
}

@MainActor
final class AIModelDisplaySizeTests: XCTestCase {
    private let key = TranscriptionEngineSelection.defaultsKey

    override func tearDownWithError() throws {
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// `size` describes the CoreML tree. On the whisper.cpp default the GGML
    /// file is roughly twice as large for the smaller models, so showing `size`
    /// understated the download by 2×.
    func testDisplaySizeFollowsTheSelectedEngine() {
        guard let base = AIModel.model(for: "openai_whisper-base.en") else {
            return XCTFail("missing base.en model")
        }

        UserDefaults.standard.set("whispercpp", forKey: key)
        XCTAssertEqual(base.displaySize, base.ggmlSize)
        XCTAssertEqual(base.displaySize, "148 MB")

        UserDefaults.standard.set("whisperkit", forKey: key)
        XCTAssertEqual(base.displaySize, base.size)
        XCTAssertEqual(base.displaySize, "74 MB")
    }

    /// Guards the validation floor against the real upstream file sizes: a
    /// threshold above the true size would reject every complete download.
    func testGgmlValidationFloorIsBelowActualUpstreamSize() {
        let actualBytes: [String: Int64] = [
            "openai_whisper-large-v3_turbo": 1_624_555_275,
            "openai_whisper-medium": 1_533_763_059,
            "openai_whisper-small.en": 487_614_201,
            "openai_whisper-base.en": 147_964_211,
            "openai_whisper-tiny": 77_691_713,
        ]
        for (variant, actual) in actualBytes {
            guard let model = AIModel.model(for: variant) else {
                XCTFail("missing model \(variant)")
                continue
            }
            XCTAssertLessThanOrEqual(
                model.ggmlExpectedSizeBytes, actual,
                "\(variant): validation floor exceeds the real file size")
            XCTAssertLessThanOrEqual(
                ModelDownloadService.minimumAcceptableSize(
                    forExpected: model.ggmlExpectedSizeBytes),
                actual, "\(variant): 80% floor exceeds the real file size")
        }
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
