import Foundation
import OSLog

/// Central definition of where AI models live on disk.
///
/// Models belong in Application Support (app-managed data), not ~/Documents —
/// upstream used the WhisperKit default of Documents/huggingface, which both
/// clutters the user's documents and forces a Documents-folder TCC prompt.
/// Keeping the `huggingface` directory name preserves the HubApi layout
/// (`huggingface/models/argmaxinc/whisperkit-coreml/<variant>`).
enum ModelStorage {
    /// Base directory passed to WhisperKit as `downloadBase`:
    /// ~/Library/Application Support/SpeakType/huggingface
    static var baseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeakType/huggingface")
    }

    /// Directory containing the WhisperKit model variants.
    static var whisperKitModelsURL: URL {
        baseURL.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
    }

    /// Folder for a specific model variant.
    static func modelFolderURL(variant: String) -> URL {
        whisperKitModelsURL.appendingPathComponent(variant)
    }

    /// One-time migration from the legacy ~/Documents/huggingface location.
    /// A same-volume move is an instant rename, so multi-GB models migrate
    /// without copying. Reading Documents may trigger a final TCC prompt;
    /// after migration the app never touches Documents again.
    static func migrateFromDocumentsIfNeeded() {
        let fm = FileManager.default
        guard let documentsDir = fm.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return }

        let legacyURL = documentsDir.appendingPathComponent("huggingface")
        guard fm.fileExists(atPath: legacyURL.path),
            !fm.fileExists(atPath: baseURL.path)
        else { return }

        do {
            try fm.createDirectory(
                at: baseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: legacyURL, to: baseURL)
            AppLogger.models.info("Migrated models from Documents/huggingface to Application Support")
        } catch {
            AppLogger.error(
                "Model migration from Documents failed — falling back to fresh downloads",
                error: error,
                category: AppLogger.models
            )
        }
    }
}
