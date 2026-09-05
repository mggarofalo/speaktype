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

    let ggml = GgmlModelDownloadService.shared

    private var whisperKitStorage: ModelDownloadService?
    private var cancellables = Set<AnyCancellable>()

    init() {
        observe(ggml)
    }

    nonisolated deinit {}

    /// The CoreML catalog is expensive to construct because it owns the
    /// WhisperKit cache. Keep it out of the default whisper.cpp launch path and
    /// create it only if the user selects WhisperKit.
    var whisperKit: ModelDownloadService {
        if let whisperKitStorage { return whisperKitStorage }

        let service = ModelDownloadService.shared
        whisperKitStorage = service
        observe(service)
        return service
    }

    private func observe(_ service: some ObservableObject) {
        service.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// The catalog service for the currently selected engine.
    var active: any ModelCatalogService {
        TranscriptionEngineSelection.current == .whispercpp ? ggml : whisperKit
    }

    var downloadProgress: [String: Double] { active.downloadProgress }
    var isDownloading: [String: Bool] { active.isDownloading }
    var downloadError: [String: String] { active.downloadError }

    /// whisper.cpp checks its single model files directly. WhisperKit builds an
    /// asynchronous inventory the first time its lazy catalog is used.
    var isActiveInventoryReady: Bool {
        TranscriptionEngineSelection.current == .whispercpp || whisperKit.isInventoryReady
    }

    func ensureActiveInventoryReady() async {
        guard TranscriptionEngineSelection.current == .whisperkit else {
            return
        }

        await whisperKit.ensureInventoryReady()
    }

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
        guard !variant.isEmpty else {
            return false
        }

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
