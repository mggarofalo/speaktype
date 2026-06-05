import XCTest
@testable import speaktype

final class ModelDownloadServiceTests: XCTestCase {
    
    func testInitialState() {
        let service = ModelDownloadService.shared

        // downloadError is only ever populated when a download actually fails,
        // and no download is started in a unit-test run, so it must be empty.
        XCTAssertTrue(service.downloadError.isEmpty)

        // The init-time disk scan (refreshDownloadedModels) may record progress
        // for already-downloaded models, but it never marks a model as actively
        // downloading and never records a fractional (in-flight) progress value.
        // Assert those invariants rather than blanket emptiness, which would be
        // flaky on a machine that already has models on disk.
        XCTAssertFalse(
            service.isDownloading.values.contains(true),
            "No model should be actively downloading at rest"
        )
        for progress in service.downloadProgress.values {
            XCTAssertFalse(
                progress > 0 && progress < 1,
                "No model should have an in-flight (fractional) progress value at rest"
            )
        }
    }
    
    // Real download tests require mocking backend connections or WhisperKit, which is out of scope for basic unit tests without dependency injection.
    // We verified the model IDs in the previous verification step.
}
