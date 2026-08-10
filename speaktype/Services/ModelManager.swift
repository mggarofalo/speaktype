import Combine
import Foundation

/// Engine-agnostic model-management surface shared by the WhisperKit (CoreML)
/// and whisper.cpp (GGML) download services, so the model-picker UI is reused.
protocol ModelCatalogService: AnyObject {
    var downloadProgress: [String: Double] { get }
    var isDownloading: [String: Bool] { get }
    var downloadError: [String: String] { get }

    func refreshDownloadedModels() async
    func downloadModel(variant: String)
    func deleteModel(variant: String) async -> String
    func cancelDownload(for variant: String)
}

/// Single ObservableObject the model-picker views observe. Forwards to whichever
/// engine's catalog service is active (per `transcriptionEngine`), and re-emits
/// either child's changes so the UI reflects per-engine download state.
class ModelManager: ObservableObject {
    static let shared = ModelManager()

    let whisperKit = ModelDownloadService.shared
    let ggml = GgmlModelDownloadService.shared

    private var cancellables = Set<AnyCancellable>()

    init() {
        whisperKit.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        ggml.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    nonisolated deinit {}

    /// The catalog service for the currently selected engine.
    var active: any ModelCatalogService {
        TranscriptionEngineSelection.current == .whispercpp ? ggml : whisperKit
    }

    var downloadProgress: [String: Double] { active.downloadProgress }
    var isDownloading: [String: Bool] { active.isDownloading }
    var downloadError: [String: String] { active.downloadError }

    /// Whether `variant` is present on disk for the *currently selected* engine.
    ///
    /// Always go through this rather than reading `ModelDownloadService.shared`
    /// directly: that service only ever knows about CoreML models, so on the
    /// whisper.cpp path (the default) it reports every model as missing.
    ///
    /// The whisper.cpp side hits storage instead of the published progress map,
    /// which is populated by an async refresh and is therefore empty during the
    /// window right after launch.
    func isDownloaded(variant: String) -> Bool {
        guard !variant.isEmpty else { return false }
        if TranscriptionEngineSelection.current == .whispercpp {
            return WhisperCppModelStorage.isDownloaded(variant: variant)
        }
        return (whisperKit.downloadProgress[variant] ?? 0) >= 1.0
    }

    /// Whether any model is available for the currently selected engine.
    var hasAnyDownloadedModel: Bool {
        if TranscriptionEngineSelection.current == .whispercpp {
            return AIModel.availableModels.contains {
                WhisperCppModelStorage.isDownloaded(variant: $0.variant)
            }
        }
        return whisperKit.downloadProgress.values.contains { $0 >= 1.0 }
    }

    func refreshDownloadedModels() async { await active.refreshDownloadedModels() }
    func downloadModel(variant: String) { active.downloadModel(variant: variant) }
    func deleteModel(variant: String) async -> String { await active.deleteModel(variant: variant) }
    func cancelDownload(for variant: String) { active.cancelDownload(for: variant) }
}
