import Foundation
import OSLog

enum WhisperCppModelStorageError: Error, LocalizedError {
    case unknownVariant(String)
    case badStatus(Int)
    case truncated(expected: Int64, got: Int64)

    var errorDescription: String? {
        switch self {
        case .unknownVariant(let v): return "No whisper.cpp GGML model mapping for variant \(v)"
        case .badStatus(let code): return "Model download failed with HTTP \(code)"
        case let .truncated(expected, got):
            return "Model download incomplete: expected \(expected) bytes, got \(got)"
        }
    }
}

/// Streams a download straight to a file handle off the main actor.
///
/// Replaces the previous `URLSession.bytes` + per-byte `for await` loop, which
/// paid an actor hop per byte. Delegate callbacks deliver whole chunks, so the
/// cost is per-chunk rather than per-byte.
///
/// `nonisolated` is load-bearing: the target sets
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so without it every callback
/// would hop to the main actor and contend with SwiftUI rendering.
private nonisolated final class StreamingDownloader:
    NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    private let alreadyHave: Int64
    private let onProgress: @Sendable (Double) -> Void
    private let onRestart: @Sendable () -> Void

    private var received: Int64 = 0
    private var total: Int64 = 0
    private var continuation: CheckedContinuation<Int64, Error>?

    // Instrumentation: splits wall-clock into "blocked on network" vs "writing",
    // so a slow download can be attributed rather than guessed at.
    private var started = Date()
    private var lastChunkEnded = Date()
    private var waitSeconds: Double = 0
    private var writeSeconds: Double = 0
    private var chunkCount = 0

    init(
        handle: FileHandle,
        alreadyHave: Int64,
        onProgress: @escaping @Sendable (Double) -> Void,
        onRestart: @escaping @Sendable () -> Void
    ) {
        self.handle = handle
        self.alreadyHave = alreadyHave
        self.onProgress = onProgress
        self.onRestart = onRestart
    }

    func run(request: URLRequest) async throws -> Int64 {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                self.continuation = cont
                self.started = Date()
                self.lastChunkEnded = Date()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }

        switch http.statusCode {
        case 206:
            // Range honoured — we are appending to what is already on disk.
            total = alreadyHave + response.expectedContentLength
        case 200:
            // Range ignored (or none sent): the body is the whole file, so any
            // existing bytes are meaningless. Rewind and start over.
            if alreadyHave > 0 {
                try? handle.truncate(atOffset: 0)
                try? handle.seek(toOffset: 0)
                received = -alreadyHave  // cancels out the offset in progress math
                onRestart()
            }
            total = response.expectedContentLength
        default:
            completionHandler(.cancel)
            finish(.failure(WhisperCppModelStorageError.badStatus(http.statusCode)))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let chunkStart = Date()
        waitSeconds += chunkStart.timeIntervalSince(lastChunkEnded)

        do {
            try handle.write(contentsOf: data)
        } catch {
            dataTask.cancel()
            finish(.failure(error))
            return
        }

        received += Int64(data.count)
        chunkCount += 1
        let now = Date()
        writeSeconds += now.timeIntervalSince(chunkStart)
        lastChunkEnded = now

        if total > 0 {
            onProgress(Double(alreadyHave + received) / Double(total))
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
        } else {
            logSummary()
            finish(.success(alreadyHave + received))
        }
    }

    private func logSummary() {
        let elapsed = Date().timeIntervalSince(started)
        // Multi-line `else` is deliberate: SwiftLint's empty_line_after_guard
        // false-positives on an inline `else { return }` even when the blank
        // line is present.
        guard elapsed > 0, received > 0 else {
            return
        }

        let mbps = Double(received) / elapsed / 1_048_576
        let avgChunk = chunkCount > 0 ? received / Int64(chunkCount) : 0
        // .notice, not .info: info-level entries are memory-only and are not
        // retrievable with `log show` after the fact, which makes a timing
        // diagnostic useless unless you happen to be streaming when it fires.
        //
        // Every value needs an explicit format + `privacy: .public`. OSLog
        // redacts interpolated strings by default, so a `String(format:)` here
        // logs as `<private>` and the whole diagnostic is worthless.
        AppLogger.models.notice(
            """
            ggml download finished: \(self.received, privacy: .public) bytes in \
            \(elapsed, format: .fixed(precision: 2), privacy: .public)s = \
            \(mbps, format: .fixed(precision: 2), privacy: .public) MB/s | \
            blocked-on-network \
            \(self.waitSeconds, format: .fixed(precision: 2), privacy: .public)s, \
            writing \(self.writeSeconds, format: .fixed(precision: 2), privacy: .public)s | \
            \(self.chunkCount, privacy: .public) chunks, avg \
            \(avgChunk, privacy: .public) bytes/chunk
            """
        )
    }

    private func finish(_ result: Result<Int64, Error>) {
        guard let cont = continuation else {
            return
        }

        continuation = nil
        cont.resume(with: result)
    }
}

/// Storage + on-demand download for whisper.cpp GGML models, kept separate from
/// the WhisperKit CoreML model tree (ModelStorage). Models are single `.bin`
/// files keyed by the same canonical `variant` ids used everywhere else.
nonisolated enum WhisperCppModelStorage {
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

    /// Scratch file a partial download accumulates into. Exposed so cancellation
    /// can clean it up instead of stranding it on disk.
    static func partialURL(for variant: String) -> URL? {
        modelURL(for: variant)?.appendingPathExtension("partial")
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
    ///
    /// Resumes from any existing `.partial` via a Range request, so an
    /// interrupted download does not start over.
    static func ensureModel(
        variant: String,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        guard let dest = modelURL(for: variant), let remote = downloadURL(for: variant),
            let tmpURL = partialURL(for: variant)
        else {
            throw WhisperCppModelStorageError.unknownVariant(variant)
        }
        if isDownloaded(variant: variant) { return dest }

        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        // Resume point: whatever a previous attempt already wrote.
        let alreadyHave = fileSize(at: tmpURL) ?? 0
        if alreadyHave == 0 {
            FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
        } else {
            AppLogger.models.notice("resuming \(variant, privacy: .public) from \(alreadyHave, privacy: .public) bytes")
        }

        var request = URLRequest(url: remote)
        if alreadyHave > 0 {
            request.setValue("bytes=\(alreadyHave)-", forHTTPHeaderField: "Range")
        }

        let handle = try FileHandle(forWritingTo: tmpURL)
        try handle.seekToEnd()

        let written: Int64
        do {
            let downloader = StreamingDownloader(
                handle: handle,
                alreadyHave: alreadyHave,
                onProgress: progress,
                onRestart: { AppLogger.models.notice("server ignored Range; restarting \(variant, privacy: .public)") }
            )
            written = try await downloader.run(request: request)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        // Only promote a complete file; a short read must stay a `.partial` so
        // the next attempt can resume rather than publish a corrupt model.
        let minimumAcceptable = AIModel.model(for: variant).map {
            ModelDownloadService.minimumAcceptableSize(forExpected: $0.ggmlExpectedSizeBytes)
        }
        if let minimumAcceptable, written < minimumAcceptable {
            throw WhisperCppModelStorageError.truncated(
                expected: minimumAcceptable, got: written)
        }

        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: tmpURL, to: dest)
        progress(1.0)
        return dest
    }

    /// Removes a variant's weights *and* any partial download, so cancelling or
    /// deleting never strands a multi-hundred-megabyte scratch file.
    static func delete(variant: String) throws {
        for url in [modelURL(for: variant), partialURL(for: variant)].compactMap({ $0 })
        where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func fileSize(at url: URL) -> Int64? {
        guard
            let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
            let size = values.fileSize
        else { return nil }
        return Int64(size)
    }
}
