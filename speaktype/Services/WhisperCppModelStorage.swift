import Foundation

enum WhisperCppModelStorageError: Error, LocalizedError {
    case unknownVariant(String)

    var errorDescription: String? {
        switch self {
        case .unknownVariant(let v): return "No whisper.cpp GGML model mapping for variant \(v)"
        }
    }
}

/// Storage + on-demand download for whisper.cpp GGML models, kept separate from
/// the WhisperKit CoreML model tree (ModelStorage). Models are single `.bin`
/// files keyed by the same canonical `variant` ids used everywhere else.
enum WhisperCppModelStorage {
    /// Directory holding GGML `.bin` models:
    /// ~/Library/Application Support/SpeakType/whispercpp/
    static var modelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeakType/whispercpp", isDirectory: true)
    }

    /// HuggingFace base for whisper.cpp GGML weights.
    private static let downloadBase =
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"

    /// Local file URL for a variant's GGML weights, or nil for unknown variants.
    static func modelURL(for variant: String) -> URL? {
        guard let model = AIModel.model(for: variant) else { return nil }
        return modelsDir.appendingPathComponent(model.ggmlFilename)
    }

    /// Remote download URL for a variant's GGML weights.
    static func downloadURL(for variant: String) -> URL? {
        guard let model = AIModel.model(for: variant) else { return nil }
        return URL(string: downloadBase + model.ggmlFilename)
    }

    /// A variant is downloaded when its `.bin` exists and is at least 80% of the
    /// expected size (guards against truncated/partial downloads).
    static func isDownloaded(variant: String) -> Bool {
        guard let url = modelURL(for: variant),
            let model = AIModel.model(for: variant),
            let size = fileSize(at: url)
        else { return false }
        return size >= ModelDownloadService.minimumAcceptableSize(
            forExpected: model.ggmlExpectedSizeBytes)
    }

    /// Downloads the variant's GGML model if missing. `progress` reports 0...1.
    static func ensureModel(
        variant: String,
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws -> URL {
        guard let dest = modelURL(for: variant), let remote = downloadURL(for: variant) else {
            throw WhisperCppModelStorageError.unknownVariant(variant)
        }
        if isDownloaded(variant: variant) { return dest }

        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let (bytes, response) = try await URLSession.shared.bytes(from: remote)
        let total = response.expectedContentLength
        let tmpURL = dest.appendingPathExtension("partial")
        FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmpURL)
        defer { try? handle.close() }

        var downloaded: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (1 << 20) {
                try handle.write(contentsOf: buffer)
                downloaded += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if total > 0 { progress(Double(downloaded) / Double(total)) }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        try handle.close()

        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tmpURL, to: dest)
        progress(1.0)
        return dest
    }

    static func delete(variant: String) throws {
        guard let url = modelURL(for: variant),
            FileManager.default.fileExists(atPath: url.path)
        else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func fileSize(at url: URL) -> Int64? {
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let size = values.fileSize
        else { return nil }
        return Int64(size)
    }
}
