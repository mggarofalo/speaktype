import Foundation

/// Storage + on-demand download for whisper.cpp GGML models, kept separate from
/// the WhisperKit CoreML model tree (ModelStorage). Minimal by design: the beta
/// benchmarks a single model (large-v3-turbo), so there is no model picker.
enum WhisperCppModelStorage {
    /// Directory holding GGML `.bin` models:
    /// ~/Library/Application Support/SpeakType/whispercpp/
    static var modelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeakType/whispercpp", isDirectory: true)
    }

    /// The single benchmark model: large-v3-turbo (GGML).
    static let benchmarkModelFile = "ggml-large-v3-turbo.bin"

    static var benchmarkModelURL: URL {
        modelsDir.appendingPathComponent(benchmarkModelFile)
    }

    /// HuggingFace download source for the GGML weights.
    private static let downloadURL = URL(
        string:
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")!

    static func isBenchmarkModelDownloaded() -> Bool {
        FileManager.default.fileExists(atPath: benchmarkModelURL.path)
    }

    /// Downloads the benchmark model if missing. `progress` reports 0...1.
    static func ensureBenchmarkModel(
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws -> URL {
        if isBenchmarkModelDownloaded() { return benchmarkModelURL }

        try FileManager.default.createDirectory(
            at: modelsDir, withIntermediateDirectories: true)

        let (bytes, response) = try await URLSession.shared.bytes(from: downloadURL)
        let total = response.expectedContentLength
        let tmpURL = benchmarkModelURL.appendingPathExtension("partial")
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
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        try handle.close()
        try FileManager.default.moveItem(at: tmpURL, to: benchmarkModelURL)
        progress(1.0)
        return benchmarkModelURL
    }
}
