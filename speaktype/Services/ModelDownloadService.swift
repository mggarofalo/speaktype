import Foundation
import Combine
import WhisperKit

/// Side-effect boundary for the model cache on disk. The production conformance
/// wraps `FileManager`; tests substitute an in-memory fake so the
/// model-verification and cleanup decision logic can be exercised without
/// touching the real filesystem. Only the operations the service actually uses
/// are exposed.
protocol ModelFileSystem {
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

class ModelDownloadService: ObservableObject {
    static let shared = ModelDownloadService()

    @Published var downloadProgress: [String: Double] = [:] // Map Model Variant (String) to progress
    @Published var downloadError: [String: String] = [:] // Debugging: track errors
    @Published var isDownloading: [String: Bool] = [:]

    private var activeTasks: [String: Task<Void, Never>] = [:] // Track running download tasks

    private let fileSystem: ModelFileSystem

    init(fileSystem: ModelFileSystem = SystemModelFileSystem()) {
        self.fileSystem = fileSystem

        // Force a custom cache directory to avoid "Multiple models found" conflicts
        setupCustomCache()

        // Check for already-downloaded models on launch
        Task { @MainActor in
            await refreshDownloadedModels()
            // Don't auto-select - let user explicitly pick a model which will load it
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

        var foundModels = Set<String>()

        // NOTE: WhisperKit.fetchAvailableModels() returns ALL remote models, not local ones
        // We ONLY rely on disk-based verification to check what's actually downloaded

        // Verify models actually exist on disk with proper size validation
        let whisperKitPath = ModelStorage.whisperKitModelsURL

        if fileSystem.directoryExists(at: whisperKitPath) {
            if let contents = fileSystem.contentsOfDirectory(at: whisperKitPath) {
                print("📁 Found \(contents.count) items in WhisperKit cache at \(whisperKitPath.path)")

                for item in contents {
                    let modelName = item.lastPathComponent

                    // Skip non-model directories
                    if modelName == "config.json" || modelName == ".DS_Store" {
                        continue
                    }

                    // Verify this directory has actual model files (not just empty directory)
                    if let subContents = fileSystem.contentsOfDirectory(at: item),
                       !subContents.isEmpty {

                        // Check if it has the essential files for a model
                        // (must have config.json AND a compiled .mlmodelc)
                        if Self.hasRequiredModelFiles(subContents) {
                            // Calculate total directory size
                            let directorySize = fileSystem.directorySize(at: item)
                            let expectedSize = AIModel.expectedSize(for: modelName)

                            if Self.isModelComplete(directorySize: directorySize, expectedSize: expectedSize) {
                                print("✅ Model \(modelName) verified: \(Self.formatBytes(directorySize)) (expected ~\(Self.formatBytes(expectedSize)))")
                                foundModels.insert(modelName)
                            } else {
                                let minAcceptableSize = Self.minimumAcceptableSize(forExpected: expectedSize)
                                print("⚠️ Model \(modelName) is INCOMPLETE: \(Self.formatBytes(directorySize)) < \(Self.formatBytes(minAcceptableSize)) minimum")
                            }
                        } else {
                            print("⚠️ Model \(modelName) is incomplete (missing config.json or .mlmodelc files)")
                        }
                    }
                }
            }
        } else {
            print("ℹ️ WhisperKit cache directory doesn't exist yet: \(whisperKitPath.path)")
            print("   Models will be downloaded on first use.")
        }

        await MainActor.run {
            // Clear all previous progress
            self.downloadProgress.removeAll()
            
            // Only mark models that actually exist
            for variant in foundModels {
                self.downloadProgress[variant] = 1.0
                print("✅ Marked as downloaded: \(variant)")
            }
            
            if foundModels.isEmpty {
                print("❌ No models found - all will show as 'Download' buttons")
            } else {
                print("✅ Found \(foundModels.count) usable model(s)")
            }
        }
    }
    
    // Asynchronous download using WhisperKit
    func downloadModel(variant: String) {
        guard isDownloading[variant] != true else { return }
        
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
                             self.isDownloading[variant] = false
                             self.downloadProgress[variant] = 1.0
                             self.downloadError[variant] = nil
                             self.activeTasks[variant] = nil
                         }
                     } catch {
                         if Task.isCancelled { return }
                         print("❌ Retry failed: \(error)")
                         DispatchQueue.main.async {
                             self.isDownloading[variant] = false
                             self.downloadProgress[variant] = 0.0
                             self.downloadError[variant] = "Error: \(error.localizedDescription)\n\nTry clicking the trash icon to manually clean cache."
                             self.activeTasks[variant] = nil
                         }
                     }
                     return
                }

                DispatchQueue.main.async {
                    self.isDownloading[variant] = false
                    self.downloadProgress[variant] = 0.0
                    self.downloadError[variant] = error.localizedDescription + "\n\n(Try Trash icon to clean cache)"
                    self.activeTasks[variant] = nil
                }
            }
        }
        
        activeTasks[variant] = task
    }
    
    // Aggressively deletes any potential cache for this variant
    func deleteModel(variant: String) async -> String {
        let fileManager = FileManager.default
        let searchDirs: [FileManager.SearchPathDirectory] = [.documentDirectory, .applicationSupportDirectory, .cachesDirectory]

        let patterns = Self.cleanupPatterns(for: variant)
        let modelName = Self.modelName(for: variant)

        var deletedCount = 0
        var checkedPaths: [String] = []

        print("🗑️ Searching for model caches matching: \(patterns.map { "'\($0)'" }.joined(separator: " or "))")

        // 1. Check Standard macOS Paths
        for searchDir in searchDirs {
            guard let baseDir = fileManager.urls(for: searchDir, in: .userDomainMask).first else { continue }

            // Check ./huggingface/models (HuggingFace cache)
            let hfModelsDir = baseDir.appendingPathComponent("huggingface/models")
            checkedPaths.append(hfModelsDir.path)
            deletedCount += cleanupDirectory(hfModelsDir, matchAny: patterns)

            // Check ./huggingface/hub (Alternative HF structure)
            let hfHubDir = baseDir.appendingPathComponent("huggingface/hub")
            checkedPaths.append(hfHubDir.path)
            deletedCount += cleanupDirectory(hfHubDir, matchAny: patterns)

            // Skip the old SpeakType-specific directory (no longer used)

            // Check root directory (sometimes models are here)
            deletedCount += cleanupDirectory(baseDir, matchAny: patterns)
        }

        // 2. Check ~/.cache (Common for Python/Unix HF tools)
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let dotCacheModels = homeDir.appendingPathComponent(".cache/huggingface/models")
        checkedPaths.append(dotCacheModels.path)
        deletedCount += cleanupDirectory(dotCacheModels, matchAny: patterns)

        let dotCacheHub = homeDir.appendingPathComponent(".cache/huggingface/hub")
        checkedPaths.append(dotCacheHub.path)
        deletedCount += cleanupDirectory(dotCacheHub, matchAny: patterns)

        // 3. Check Temporary Directory
        let tempDir = fileManager.temporaryDirectory
        let tempHf = tempDir.appendingPathComponent("huggingface")
        checkedPaths.append(tempHf.path)
        deletedCount += cleanupDirectory(tempHf, matchAny: patterns)
        deletedCount += cleanupDirectory(tempDir, matchAny: patterns)

        // 4. Check Documents/huggingface/models/argmaxinc/whisperkit-coreml (standard location)
        if let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let whisperKitModels = documentsDir.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
            checkedPaths.append(whisperKitModels.path)
            deletedCount += cleanupDirectory(whisperKitModels, matchAny: patterns)
        }

        print("🗑️ Cleanup complete. Deleted \(deletedCount) items from \(checkedPaths.count) locations")

        if deletedCount > 0 {
            await MainActor.run {
                self.downloadProgress[variant] = 0.0
                self.isDownloading[variant] = false
            }
            return "Deleted \(deletedCount) items"
        } else {
            await MainActor.run {
                self.downloadProgress[variant] = 0.0
                self.isDownloading[variant] = false
            }
            return "No match for '\(modelName)' in \(checkedPaths.count) locations. checked: \(checkedPaths.map { $0.replacingOccurrences(of: homeDir.path, with: "~") }.joined(separator: ", "))"
        }
    }

    @discardableResult
    private func cleanupDirectory(_ dir: URL, matchAny patterns: [String]) -> Int {
        guard let contents = fileSystem.contentsOfDirectory(at: dir) else { return 0 }

        var count = 0
        for url in contents where Self.matchesCleanupPattern(url.lastPathComponent, patterns: patterns) {
            do {
                try fileSystem.removeItem(at: url)
                print("✅ Deleted cache: \(url.lastPathComponent)")
                count += 1
            } catch {
                print("❌ Failed to delete \(url.lastPathComponent): \(error)")
            }
        }
        return count
    }
    func cancelDownload(for variant: String) {
        if let task = activeTasks[variant] {
            task.cancel()
            activeTasks[variant] = nil
            print("Cancelled download task for \(variant)")
        }
        
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
    static func hasRequiredModelFiles(_ contents: [URL]) -> Bool {
        let hasConfigJson = contents.contains { $0.lastPathComponent == "config.json" }
        let hasModelFiles = contents.contains { $0.lastPathComponent.hasSuffix(".mlmodelc") }
        return hasConfigJson && hasModelFiles
    }

    /// A model is treated as fully downloaded once its on-disk size reaches 80%
    /// of the expected size — WhisperKit's bundles vary slightly and a partial
    /// download falls well short of this threshold.
    static func minimumAcceptableSize(forExpected expectedSize: Int64) -> Int64 {
        Int64(Double(expectedSize) * 0.8)
    }

    static func isModelComplete(directorySize: Int64, expectedSize: Int64) -> Bool {
        directorySize >= minimumAcceptableSize(forExpected: expectedSize)
    }

    /// The bare model name from a variant: the last `/`-separated component, so
    /// "openai/whisper-medium" → "whisper-medium" and a slash-free
    /// "openai_whisper-medium" is returned unchanged.
    static func modelName(for variant: String) -> String {
        String(variant.split(separator: "/").last ?? Substring(variant))
    }

    /// Cache-directory name patterns to match when deleting a variant: the bare
    /// model name plus the underscore-normalised variant ("openai/whisper-medium"
    /// → "openai_whisper-medium"), covering both HuggingFace layouts.
    static func cleanupPatterns(for variant: String) -> [String] {
        [modelName(for: variant), variant.replacingOccurrences(of: "/", with: "_")]
    }

    /// A directory entry matches if its name contains any pattern, or the
    /// pattern's `--`-normalised form (the HF hub uses "owner--repo" folders).
    static func matchesCleanupPattern(_ fileName: String, patterns: [String]) -> Bool {
        patterns.contains { pattern in
            fileName.contains(pattern)
                || fileName.contains(pattern.replacingOccurrences(of: "/", with: "--"))
        }
    }

    // MARK: - Helper Functions

    /// Calculate total size of a directory recursively
    static func calculateDirectorySize(at url: URL) -> Int64 {
        let fileManager = FileManager.default
        var totalSize: Int64 = 0
        
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) else {
            return 0
        }
        
        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if resourceValues.isRegularFile == true {
                    totalSize += Int64(resourceValues.fileSize ?? 0)
                }
            } catch {
                continue
            }
        }
        
        return totalSize
    }
    
    /// Format bytes into human-readable string
    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

/// Production conformance: the original `FileManager` code, verbatim.
struct SystemModelFileSystem: ModelFileSystem {
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
