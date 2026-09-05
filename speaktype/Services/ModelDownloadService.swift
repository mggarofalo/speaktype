import Foundation
import Combine
import WhisperKit

/// Side-effect boundary for the model cache on disk. The production conformance
/// wraps `FileManager`; tests substitute an in-memory fake so the
/// model-verification and cleanup decision logic can be exercised without
/// touching the real filesystem. Only the operations the service actually uses
/// are exposed.
nonisolated protocol ModelFileSystem: Sendable {
    /// True when a directory (or file) exists at `url`.
    func directoryExists(at url: URL) -> Bool
    /// Immediate children of `url`, or nil if it cannot be read.
    func contentsOfDirectory(at url: URL) -> [URL]?
    /// Total size in bytes of all regular files under `url` (recursive).
    func directorySize(at url: URL) -> Int64
    /// Create the directory at `url`, including intermediates.
    func createDirectory(at url: URL) throws
    /// Remove the item at `url`.
    func removeItem(at url: URL) throws
}

class ModelDownloadService: ObservableObject, ModelCatalogService {
    static let shared = ModelDownloadService()

    @Published var downloadProgress: [String: Double] = [:] // Map Model Variant (String) to progress
    @Published var downloadError: [String: String] = [:] // Debugging: track errors
    @Published var isDownloading: [String: Bool] = [:]
    @Published private(set) var isInventoryReady = false

    private var activeTasks: [String: Task<Void, Never>] = [:] // Track running download tasks
    private var initialInventoryTask: Task<Void, Never>?
    private var catalogRevision = 0
    private var refreshSequence = 0

    private let fileSystem: ModelFileSystem

    init(fileSystem: ModelFileSystem = SystemModelFileSystem()) {
        self.fileSystem = fileSystem

        // Force a custom cache directory to avoid "Multiple models found" conflicts
        setupCustomCache()

        // ModelManager constructs this service lazily, only on the WhisperKit
        // path. Once constructed, bootstrap inventory so hotkey-only users do
        // not have to visit AI Models after every relaunch.
        initialInventoryTask = Task { @MainActor [weak self] in
            guard let self, self.refreshSequence == 0 else { return }
            await self.refreshDownloadedModels()
        }
    }

    // The project defaults to MainActor isolation, which would give this type a
    // main-actor-isolated deinit. There is no main-actor state to tear down, and
    // the back-deployed main-actor deinit path crashes when a non-`shared`
    // instance is released under test. A nonisolated deinit avoids that hop.
    nonisolated deinit {}

    private func setupCustomCache() {
        // Models live in Application Support (see ModelStorage). Move any
        // legacy Documents/huggingface install first, then ensure the dir.
        ModelStorage.migrateFromDocumentsIfNeeded()

        do {
            try fileSystem.createDirectory(at: ModelStorage.baseURL)
            print("✅ Using model cache at: \(ModelStorage.baseURL.path)")
        } catch {
            print("⚠️ Failed to create model cache directory: \(error)")
        }
    }

    // Check which models are already downloaded and update progress dictionary
    func refreshDownloadedModels() async {
        print("🔍 Checking for already-downloaded models...")
        refreshSequence += 1
        let sequence = refreshSequence
        let startingRevision = catalogRevision
        let whisperKitPath = ModelStorage.whisperKitModelsURL
        let expectedSizes = Dictionary(
            uniqueKeysWithValues: AIModel.availableModels.map { ($0.variant, $0.expectedSizeBytes) })
        let fileSystem = fileSystem

        let foundModels = await Task.detached(priority: .utility) {
            Self.scanDownloadedModels(
                fileSystem: fileSystem,
                rootURL: whisperKitPath,
                expectedSizes: expectedSizes
            )
        }.value

        // A later refresh or a download/delete that completed during this scan
        // owns newer state. Do not let this older disk snapshot overwrite it.
        guard sequence == refreshSequence, startingRevision == catalogRevision else {
            return
        }

        downloadProgress = Dictionary(uniqueKeysWithValues: foundModels.map { ($0, 1.0) })
        isInventoryReady = true
        if foundModels.isEmpty {
            print("❌ No models found - all will show as 'Download' buttons")
        } else {
            print("✅ Found \(foundModels.count) usable model(s)")
        }
    }

    /// Wait until at least one complete disk inventory has been published.
    /// Calls can race the bootstrap or another explicit refresh; the loop lets
    /// the newest scan win without treating an older discarded result as ready.
    func ensureInventoryReady() async {
        if isInventoryReady { return }
        await initialInventoryTask?.value

        while !isInventoryReady {
            await refreshDownloadedModels()
            if !isInventoryReady { await Task.yield() }
        }
    }

    nonisolated static func scanDownloadedModels(
        fileSystem: any ModelFileSystem,
        rootURL: URL,
        expectedSizes: [String: Int64]
    ) -> Set<String> {
        guard fileSystem.directoryExists(at: rootURL),
            let contents = fileSystem.contentsOfDirectory(at: rootURL)
        else { return [] }

        var foundModels = Set<String>()
        for item in contents {
            let variant = item.lastPathComponent
            guard let expectedSize = expectedSizes[variant],
                let subContents = fileSystem.contentsOfDirectory(at: item),
                hasRequiredModelFiles(subContents)
            else { continue }

            let size = fileSystem.directorySize(at: item)
            if isModelComplete(directorySize: size, expectedSize: expectedSize) {
                foundModels.insert(variant)
            }
        }
        return foundModels
    }
    
    // Asynchronous download using WhisperKit
    func downloadModel(variant: String) {
        guard isDownloading[variant] != true else { return }

        catalogRevision += 1
        isDownloading[variant] = true
        downloadProgress[variant] = 0.0
        downloadError[variant] = nil
        print("Starting WhisperKit download for: \(variant)")
        
        let task = Task {
            // Debug: List what WhisperKit sees
            // Note: WhisperKit API might differ, but let's try to see if we can get info.
            // If fetchAvailableModels exists.
            
            do {
                // Determine model variant enum/string
                // Note: WhisperKit.download(variant:from:) is the likely API.
                // We use the "variant" string to fetch.
                // Assuming `WhisperKit.download(variant: variant)` acts as the fetcher.
                // Progress callback mock (since we might not have exact API signature yet):
                
                // Actual API (hypothetical based on search):
                // let model = try await WhisperKit(model: variant) 
                // OR
                // try await WhisperKit.download(variant: variant) { progress in ... }
                
                // likely: download(variant:progressCallback:) - 'from' usually has a default
                let _ = try await WhisperKit.download(
                    variant: variant,
                    downloadBase: ModelStorage.baseURL,
                    progressCallback: { progress in
                        DispatchQueue.main.async {
                            self.downloadProgress[variant] = progress.fractionCompleted
                        }
                    })
                
                // Check if task was cancelled before declaring success
                if Task.isCancelled { return }
                
                print("Model downloaded successfully")
                
                DispatchQueue.main.async {
                    self.catalogRevision += 1
                    self.isDownloading[variant] = false
                    self.downloadProgress[variant] = 1.0
                    self.activeTasks[variant] = nil // Cleanup task
                }
            } catch {
                if Task.isCancelled {
                   print("Download cancelled for \(variant)")
                   return
                }
                
                print("WhisperKit download error: \(error)")
                
                // Auto-Repair: If duplicate models found, delete and retry ONCE
                if error.localizedDescription.contains("Multiple models found") {
                     print("⚠️ Multiple models detected. Cleaning cache and retrying...")
                     
                     await MainActor.run {
                         self.downloadError[variant] = "Cleaning duplicates..."
                     }
                     
                     let log = await self.deleteModel(variant: variant)
                     print("🧹 Cleanup result: \(log)")
                     
                     // Give filesystem time to settle
                     try? await Task.sleep(nanoseconds: 2_000_000_000)
                     if Task.isCancelled { return }
                     
                     await MainActor.run {
                         self.downloadError[variant] = "Retrying download..."
                         self.isDownloading[variant] = true
                     }
                     
                     // Retry download once
                     do {
                         let _ = try await WhisperKit.download(
                             variant: variant,
                             downloadBase: ModelStorage.baseURL,
                             progressCallback: { progress in
                                 DispatchQueue.main.async {
                                     self.downloadProgress[variant] = progress.fractionCompleted
                                 }
                             })
                         
                         if Task.isCancelled { return }
                         
                         print("✅ Model downloaded successfully after cleanup")
                         
                         DispatchQueue.main.async {
                             self.catalogRevision += 1
                             self.isDownloading[variant] = false
                             self.downloadProgress[variant] = 1.0
                             self.downloadError[variant] = nil
                             self.activeTasks[variant] = nil
                         }
                     } catch {
                         if Task.isCancelled { return }
                         print("❌ Retry failed: \(error)")
                         DispatchQueue.main.async {
                             self.catalogRevision += 1
                             self.isDownloading[variant] = false
                             self.downloadProgress[variant] = 0.0
                             self.downloadError[variant] =
                                 "Error: \(error.localizedDescription)\n\nTry deleting the model and downloading it again."
                             self.activeTasks[variant] = nil
                         }
                     }
                     return
                }

                DispatchQueue.main.async {
                    self.catalogRevision += 1
                    self.isDownloading[variant] = false
                    self.downloadProgress[variant] = 0.0
                    self.downloadError[variant] = error.localizedDescription + "\n\n(Try Trash icon to clean cache)"
                    self.activeTasks[variant] = nil
                }
            }
        }
        
        activeTasks[variant] = task
    }
    
    /// Delete only the model directory owned by SpeakType. Older code searched
    /// broad user cache, Documents, Application Support, and temp directories by
    /// substring, which could remove another app's HuggingFace data.
    func deleteModel(variant: String) async -> String {
        guard AIModel.model(for: variant) != nil else {
            return "Unknown model '\(variant)'"
        }

        let target = ModelStorage.modelFolderURL(variant: variant)
        let fileSystem = fileSystem
        do {
            let deleted = try await Task.detached(priority: .utility) {
                guard fileSystem.directoryExists(at: target) else { return false }
                try fileSystem.removeItem(at: target)
                return true
            }.value

            catalogRevision += 1
            downloadProgress[variant] = 0.0
            isDownloading[variant] = false
            downloadError[variant] = nil
            return deleted ? "Removed \(variant)" : "No downloaded files for \(variant)"
        } catch {
            downloadError[variant] = error.localizedDescription
            return "Failed to remove \(variant): \(error.localizedDescription)"
        }
    }

    func cancelDownload(for variant: String) {
        if let task = activeTasks[variant] {
            task.cancel()
            activeTasks[variant] = nil
            print("Cancelled download task for \(variant)")
        }
        
        catalogRevision += 1
        isDownloading[variant] = false
        downloadProgress[variant] = 0.0
        downloadError[variant] = nil
        
        // Delete any partial download
        Task {
            let result = await deleteModel(variant: variant)
            print("🗑️ Cleaned up partial download: \(result)")
        }
    }
    
    // MARK: - Pure Decision Logic

    /// A downloaded model directory must contain both a `config.json` and at
    /// least one compiled `.mlmodelc` to be considered usable. An empty or
    /// partially-downloaded directory has neither.
    nonisolated static func hasRequiredModelFiles(_ contents: [URL]) -> Bool {
        let hasConfigJson = contents.contains { $0.lastPathComponent == "config.json" }
        let hasModelFiles = contents.contains { $0.lastPathComponent.hasSuffix(".mlmodelc") }
        return hasConfigJson && hasModelFiles
    }

    /// A model is treated as fully downloaded once its on-disk size reaches 80%
    /// of the expected size — WhisperKit's bundles vary slightly and a partial
    /// download falls well short of this threshold.
    nonisolated static func minimumAcceptableSize(forExpected expectedSize: Int64) -> Int64 {
        Int64(Double(expectedSize) * 0.8)
    }

    nonisolated static func isModelComplete(directorySize: Int64, expectedSize: Int64) -> Bool {
        directorySize >= minimumAcceptableSize(forExpected: expectedSize)
    }

    // MARK: - Helper Functions

    /// Calculate total size of a directory recursively
    nonisolated static func calculateDirectorySize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        var totalSize: Int64 = 0
        
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        
        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey])
                if resourceValues.isRegularFile == true {
                    totalSize += Int64(resourceValues.fileSize ?? 0)
                }
            } catch {
                continue
            }
        }
        
        return totalSize
    }
}

/// Production conformance: the original `FileManager` code, verbatim.
nonisolated struct SystemModelFileSystem: ModelFileSystem {
    func directoryExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func contentsOfDirectory(at url: URL) -> [URL]? {
        try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }

    func directorySize(at url: URL) -> Int64 {
        ModelDownloadService.calculateDirectorySize(at: url)
    }

    func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}
