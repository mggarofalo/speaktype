@testable import speaktype
import XCTest

@MainActor
final class AIModelsViewTests: XCTestCase {
    func testReconciliationKeepsDownloadedCurrentSelection() {
        let models = AIModel.availableModels
        let current = models[2].variant

        let result = AIModelsView.reconciledSelection(
            current: current,
            models: models,
            isDownloaded: { $0 == current }
        )

        XCTAssertEqual(result, current)
    }

    func testReconciliationFallsBackInCatalogOrder() {
        let models = AIModel.availableModels
        let downloaded = [models[1].variant, models[3].variant]

        let result = AIModelsView.reconciledSelection(
            current: "missing-model",
            models: models,
            isDownloaded: downloaded.contains
        )

        XCTAssertEqual(result, models[1].variant)
    }

    func testReconciliationClearsMissingSelectionWhenNothingIsDownloaded() {
        let result = AIModelsView.reconciledSelection(
            current: "missing-model",
            models: AIModel.availableModels,
            isDownloaded: { _ in false }
        )

        XCTAssertEqual(result, "")
    }

    func testReconciliationSelectsFirstDownloadedModelWhenSelectionIsEmpty() {
        let firstModel = AIModel.availableModels[0]

        let result = AIModelsView.reconciledSelection(
            current: "",
            models: AIModel.availableModels,
            isDownloaded: { $0 == firstModel.variant }
        )

        XCTAssertEqual(result, firstModel.variant)
    }
}
