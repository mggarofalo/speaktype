import Foundation
@_exported import whisper

public enum WhisperCPPError: Error, LocalizedError {
    case modelLoadFailed(String)
    case notInitialized
    case transcriptionFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path): return "Failed to load whisper.cpp model at \(path)"
        case .notInitialized: return "whisper.cpp context is not initialized"
        case .transcriptionFailed(let code): return "whisper_full failed with code \(code)"
        }
    }
}

/// Thin Swift wrapper over the whisper.cpp C API. Isolates all C interop so the
/// app target deals only in Swift types. GPU (Metal) is on by default.
public final class WhisperCPPContext {
    private var ctx: OpaquePointer?

    public init(modelPath: String, useGPU: Bool = true) throws {
        var cparams = whisper_context_default_params()
        cparams.use_gpu = useGPU
        guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw WhisperCPPError.modelLoadFailed(modelPath)
        }
        self.ctx = ctx
    }

    deinit {
        if let ctx { whisper_free(ctx) }
    }

    /// Transcribe 16 kHz mono Float PCM samples (range -1...1).
    /// `language` is an ISO code (e.g. "en") or nil for auto-detect.
    public func transcribe(samples: [Float], language: String?, threads: Int32) throws -> String {
        guard let ctx else { throw WhisperCPPError.notInitialized }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.n_threads = threads
        params.detect_language = (language == nil)

        let run: (UnsafePointer<CChar>?) throws -> String = { langPtr in
            params.language = langPtr
            let ret = samples.withUnsafeBufferPointer { buf in
                whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
            }
            guard ret == 0 else { throw WhisperCPPError.transcriptionFailed(ret) }

            var text = ""
            let segments = whisper_full_n_segments(ctx)
            for i in 0..<segments {
                if let cstr = whisper_full_get_segment_text(ctx, i) {
                    text += String(cString: cstr)
                }
            }
            return text
        }

        if let language {
            return try language.withCString { try run($0) }
        } else {
            return try run(nil)
        }
    }
}
