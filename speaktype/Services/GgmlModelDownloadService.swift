import Combine
import Foundation

/// Download/verify/delete for whisper.cpp GGML models, mirroring
/// ModelDownloadService's surface (ModelCatalogService) so the model-picker UI
/// works unchanged for the whisper.cpp engine. Backed by WhisperCppModelStorage.
class GgmlModelDownloadService: ObservableObject, ModelCatalogService {
    static let shared = GgmlModelDownloadService()

    @Published var downloadProgress: [String: Double] = [:]
    @Published var downloadError: [String: String] = [:]
    @Published var isDownloading: [String: Bool] = [:]

    private var activeTasks: [String: Task<Void, Never>] = [:]

    init() {
        Task { @MainActor in await refreshDownloadedModels() }
    }

    // See ModelDownloadService: the project's default MainActor isolation would
    // give a main-actor deinit that crashes for non-`shared` instances under test.
    nonisolated deinit {}

    func refreshDownloadedModels() async {
        for model in AIModel.availableModels {
            if WhisperCppModelStorage.isDownloaded(variant: model.variant) {
                downloadProgress[model.variant] = 1.0
            } else if (downloadProgress[model.variant] ?? 0) >= 1.0 {
                // Was marked complete but file is now gone — reset.
                downloadProgress[model.variant] = 0.0
            }
        }
    }

    func downloadModel(variant: String) {
        guard isDownloading[variant] != true else { return }
        isDownloading[variant] = true
        downloadError[variant] = nil
        downloadProgress[variant] = 0.0

        activeTasks[variant] = Task { @MainActor in
            do {
                _ = try await WhisperCppModelStorage.ensureModel(variant: variant) { progress in
                    Task { @MainActor in self.downloadProgress[variant] = progress }
                }
                downloadProgress[variant] = 1.0
            } catch {
                if !(error is CancellationError) {
                    downloadError[variant] = error.localizedDescription
                }
                downloadProgress[variant] = 0.0
            }
            isDownloading[variant] = false
            activeTasks[variant] = nil
        }
    }

    func deleteModel(variant: String) async -> String {
        do {
            try WhisperCppModelStorage.delete(variant: variant)
            downloadProgress[variant] = 0.0
            isDownloading[variant] = false
            return "Removed \(variant)"
        } catch {
            return "Failed to remove \(variant): \(error.localizedDescription)"
        }
    }

    func cancelDownload(for variant: String) {
        activeTasks[variant]?.cancel()
        activeTasks[variant] = nil
        isDownloading[variant] = false
        downloadProgress[variant] = 0.0
        try? WhisperCppModelStorage.delete(variant: variant)
    }
}
