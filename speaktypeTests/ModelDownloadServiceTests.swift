import XCTest
@testable import speaktype

/// In-memory fake for the model-cache filesystem seam. Models a flat map from
/// directory URL to its immediate children, plus a per-directory total size.
/// Records removals so cleanup logic can be verified without touching disk.
@MainActor
final class FakeModelFileSystem: ModelFileSystem {
    /// Immediate children keyed by directory URL.
    var children: [URL: [URL]] = [:]
    /// Recursive total size keyed by directory URL.
    var sizes: [URL: Int64] = [:]
    /// Directories that "exist" (createDirectory adds to this).
    var existingDirectories: Set<URL> = []

    private(set) var removedURLs: [URL] = []
    private(set) var createdDirectories: [URL] = []

    func directoryExists(at url: URL) -> Bool {
        existingDirectories.contains(url) || children[url] != nil
    }

    func contentsOfDirectory(at url: URL) -> [URL]? {
        children[url]
    }

    func directorySize(at url: URL) -> Int64 {
        sizes[url] ?? 0
    }

    func createDirectory(at url: URL) throws {
        createdDirectories.append(url)
        existingDirectories.insert(url)
    }

    func removeItem(at url: URL) throws {
        removedURLs.append(url)
    }
}

@MainActor
final class ModelDownloadServiceTests: XCTestCase {

    // MARK: - Pure decision logic: model-file presence

    func testHasRequiredModelFilesTrueWhenBothConfigAndMlmodelcPresent() {
        let contents = [
            URL(fileURLWithPath: "/m/config.json"),
            URL(fileURLWithPath: "/m/AudioEncoder.mlmodelc"),
        ]
        XCTAssertTrue(ModelDownloadService.hasRequiredModelFiles(contents))
    }

    func testHasRequiredModelFilesFalseWhenConfigMissing() {
        let contents = [URL(fileURLWithPath: "/m/AudioEncoder.mlmodelc")]
        XCTAssertFalse(ModelDownloadService.hasRequiredModelFiles(contents))
    }

    func testHasRequiredModelFilesFalseWhenMlmodelcMissing() {
        let contents = [URL(fileURLWithPath: "/m/config.json")]
        XCTAssertFalse(ModelDownloadService.hasRequiredModelFiles(contents))
    }

    func testHasRequiredModelFilesFalseWhenEmpty() {
        XCTAssertFalse(ModelDownloadService.hasRequiredModelFiles([]))
    }

    // MARK: - Pure decision logic: size threshold

    func testMinimumAcceptableSizeIs80PercentOfExpected() {
        XCTAssertEqual(ModelDownloadService.minimumAcceptableSize(forExpected: 1_000), 800)
    }

    func testIsModelCompleteAtExactlyThreshold() {
        // 80% of 1000 = 800 — the boundary is inclusive.
        XCTAssertTrue(
            ModelDownloadService.isModelComplete(directorySize: 800, expectedSize: 1_000))
    }

    func testIsModelCompleteFalseJustBelowThreshold() {
        XCTAssertFalse(
            ModelDownloadService.isModelComplete(directorySize: 799, expectedSize: 1_000))
    }

    func testIsModelCompleteTrueWellAboveThreshold() {
        XCTAssertTrue(
            ModelDownloadService.isModelComplete(directorySize: 1_500, expectedSize: 1_000))
    }

    // MARK: - Pure decision logic: variant-name parsing

    func testModelNameStripsSlashOwnerPrefix() {
        XCTAssertEqual(
            ModelDownloadService.modelName(for: "openai/whisper-medium"), "whisper-medium")
    }

    func testModelNameLeavesUnderscoreVariantUnchanged() {
        XCTAssertEqual(
            ModelDownloadService.modelName(for: "openai_whisper-medium"), "openai_whisper-medium")
    }

    func testCleanupPatternsCoversBareNameAndUnderscoreForm() {
        let patterns = ModelDownloadService.cleanupPatterns(for: "openai/whisper-medium")
        XCTAssertEqual(patterns, ["whisper-medium", "openai_whisper-medium"])
    }

    // MARK: - Pure decision logic: cleanup pattern matching

    func testMatchesCleanupPatternByBareModelName() {
        let patterns = ModelDownloadService.cleanupPatterns(for: "openai_whisper-medium")
        XCTAssertTrue(
            ModelDownloadService.matchesCleanupPattern(
                "models--openai_whisper-medium", patterns: patterns))
    }

    func testMatchesCleanupPatternByDoubleDashHubForm() {
        // HF hub uses "owner--repo" folder names; the slash form is normalised to "--".
        let patterns = ModelDownloadService.cleanupPatterns(for: "openai/whisper-medium")
        XCTAssertTrue(
            ModelDownloadService.matchesCleanupPattern(
                "models--openai--whisper-medium", patterns: patterns))
    }

    func testMatchesCleanupPatternFalseForUnrelatedName() {
        let patterns = ModelDownloadService.cleanupPatterns(for: "openai_whisper-medium")
        XCTAssertFalse(
            ModelDownloadService.matchesCleanupPattern("whisper-tiny", patterns: patterns))
    }

    // MARK: - refreshDownloadedModels via the filesystem seam

    private let whisperKitURL = ModelStorage.whisperKitModelsURL

    private func modelURL(_ name: String) -> URL {
        whisperKitURL.appendingPathComponent(name)
    }

    /// Seed one complete model directory in the fake and run a refresh.
    private func makeServiceWithModels(_ fake: FakeModelFileSystem) -> ModelDownloadService {
        ModelDownloadService(fileSystem: fake)
    }

    func testRefreshMarksCompleteModelAsDownloaded() async {
        let fake = FakeModelFileSystem()
        let model = modelURL("openai_whisper-tiny")
        fake.existingDirectories.insert(whisperKitURL)
        fake.children[whisperKitURL] = [model]
        fake.children[model] = [
            model.appendingPathComponent("config.json"),
            model.appendingPathComponent("AudioEncoder.mlmodelc"),
        ]
        // expectedSize for tiny is 30_000_000; 80% = 24_000_000.
        fake.sizes[model] = 25_000_000

        let service = makeServiceWithModels(fake)
        await service.refreshDownloadedModels()

        XCTAssertEqual(service.downloadProgress["openai_whisper-tiny"], 1.0)
    }

    func testRefreshIgnoresIncompleteModelBelowSizeThreshold() async {
        let fake = FakeModelFileSystem()
        let model = modelURL("openai_whisper-tiny")
        fake.existingDirectories.insert(whisperKitURL)
        fake.children[whisperKitURL] = [model]
        fake.children[model] = [
            model.appendingPathComponent("config.json"),
            model.appendingPathComponent("AudioEncoder.mlmodelc"),
        ]
        // Well below 80% of 30_000_000.
        fake.sizes[model] = 1_000_000

        let service = makeServiceWithModels(fake)
        await service.refreshDownloadedModels()

        XCTAssertNil(service.downloadProgress["openai_whisper-tiny"],
                     "an under-sized model must not be marked downloaded")
    }

    func testRefreshIgnoresModelMissingConfigJson() async {
        let fake = FakeModelFileSystem()
        let model = modelURL("openai_whisper-tiny")
        fake.existingDirectories.insert(whisperKitURL)
        fake.children[whisperKitURL] = [model]
        fake.children[model] = [
            model.appendingPathComponent("AudioEncoder.mlmodelc"),
        ]
        fake.sizes[model] = 25_000_000

        let service = makeServiceWithModels(fake)
        await service.refreshDownloadedModels()

        XCTAssertNil(service.downloadProgress["openai_whisper-tiny"],
                     "a model with no config.json must not be marked downloaded")
    }

    func testRefreshSkipsConfigJsonAndDSStoreEntries() async {
        let fake = FakeModelFileSystem()
        fake.existingDirectories.insert(whisperKitURL)
        // Top-level stray files that must be skipped, not treated as models.
        fake.children[whisperKitURL] = [
            whisperKitURL.appendingPathComponent("config.json"),
            whisperKitURL.appendingPathComponent(".DS_Store"),
        ]

        let service = makeServiceWithModels(fake)
        await service.refreshDownloadedModels()

        XCTAssertTrue(service.downloadProgress.isEmpty,
                      "stray config.json/.DS_Store must not be marked as models")
    }

    func testRefreshClearsStalePreviousProgress() async {
        let fake = FakeModelFileSystem()
        fake.existingDirectories.insert(whisperKitURL)
        fake.children[whisperKitURL] = []  // nothing on disk

        let service = makeServiceWithModels(fake)
        service.downloadProgress["openai_whisper-tiny"] = 1.0  // stale entry

        await service.refreshDownloadedModels()

        XCTAssertNil(service.downloadProgress["openai_whisper-tiny"],
                     "refresh must clear progress for models no longer on disk")
    }

    func testRefreshWithNoCacheDirectoryFindsNothing() async {
        let fake = FakeModelFileSystem()  // whisperKitURL does not exist
        let service = makeServiceWithModels(fake)

        await service.refreshDownloadedModels()

        XCTAssertTrue(service.downloadProgress.isEmpty)
    }

    // MARK: - deleteModel via the filesystem seam

    func testDeleteModelRemovesMatchingCacheEntries() async {
        let fake = FakeModelFileSystem()
        // Seed an HF-style cache dir under Application Support with a matching folder.
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let hfModels = appSupport.appendingPathComponent("huggingface/models")
        let match = hfModels.appendingPathComponent("models--openai_whisper-medium")
        let unrelated = hfModels.appendingPathComponent("models--openai_whisper-tiny")
        fake.children[hfModels] = [match, unrelated]

        let service = ModelDownloadService(fileSystem: fake)
        let result = await service.deleteModel(variant: "openai_whisper-medium")

        XCTAssertTrue(fake.removedURLs.contains(match),
                      "the matching cache folder should be removed")
        XCTAssertFalse(fake.removedURLs.contains(unrelated),
                       "an unrelated model's cache must not be touched")
        XCTAssertTrue(result.hasPrefix("Deleted"), "result summary reports deletions: \(result)")
    }

    func testDeleteModelReportsNoMatchWhenNothingFound() async {
        let fake = FakeModelFileSystem()  // every directory reads as empty/nil
        let service = ModelDownloadService(fileSystem: fake)

        let result = await service.deleteModel(variant: "openai_whisper-medium")

        XCTAssertTrue(fake.removedURLs.isEmpty)
        XCTAssertTrue(result.hasPrefix("No match"), "result summary reports no match: \(result)")
    }

    // MARK: - download bookkeeping

    func testDownloadModelRejectsDuplicateWhileInFlight() {
        let fake = FakeModelFileSystem()
        let service = ModelDownloadService(fileSystem: fake)

        // Simulate an in-flight download; downloadModel must early-return.
        service.isDownloading["openai_whisper-tiny"] = true
        service.downloadProgress["openai_whisper-tiny"] = 0.5

        service.downloadModel(variant: "openai_whisper-tiny")

        XCTAssertEqual(service.downloadProgress["openai_whisper-tiny"], 0.5,
                       "a duplicate download request must not reset in-flight progress")
    }

    func testCancelDownloadResetsBookkeeping() {
        let fake = FakeModelFileSystem()
        let service = ModelDownloadService(fileSystem: fake)
        service.isDownloading["openai_whisper-tiny"] = true
        service.downloadProgress["openai_whisper-tiny"] = 0.3
        service.downloadError["openai_whisper-tiny"] = "some error"

        service.cancelDownload(for: "openai_whisper-tiny")

        XCTAssertEqual(service.isDownloading["openai_whisper-tiny"], false)
        XCTAssertEqual(service.downloadProgress["openai_whisper-tiny"], 0.0)
        XCTAssertNil(service.downloadError["openai_whisper-tiny"])
    }
}
