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

    /// Builds the decode parameters. Split out from `transcribe` so tests can
    /// assert the invariants that are otherwise invisible from outside the C API.
    ///
    /// Load-bearing: `detect_language` is deliberately left at its default of
    /// false, including for auto-detect. Setting it means "detect the language
    /// and stop" — `whisper_full` returns 0 having emitted zero segments, so
    /// every dictation on the default "Auto" language came back empty and the
    /// UI reported "No speech detected". Auto-detect is requested by leaving
    /// `params.language` nil, which detects *and then transcribes*.
    public static func makeParams(
        threads: Int32, noContext: Bool, entropyThreshold: Float, temperatureIncrement: Float
    ) -> whisper_full_params {
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.n_threads = threads
        params.no_context = noContext
        params.entropy_thold = entropyThreshold
        params.temperature_inc = temperatureIncrement
        return params
    }

    /// Transcribe 16 kHz mono Float PCM samples (range -1...1).
    /// `language` is an ISO code (e.g. "en") or nil for auto-detect.
    /// `initialPrompt` biases decoding toward given spellings (custom vocabulary).
    ///
    /// Loop resistance. A 146s dictation degenerated into "…run the application"
    /// repeated to the end; `entropyThreshold = 3.0` (up from whisper.cpp's 2.4
    /// default) is what fixes it — empirically: 21× repeated 5-gram → 1×, while
    /// a normal short clip transcribes byte-identically to the 2.4 default.
    ///
    /// `entropyThreshold` + `temperatureIncrement` drive whisper.cpp's built-in
    /// anti-repetition fallback: a segment whose token entropy falls below the
    /// threshold (the signature of a loop) is re-decoded at a higher temperature
    /// instead of being emitted. Only low-entropy segments are affected, so
    /// raising the bar to 3.0 catches loops without disturbing normal speech.
    ///
    /// `noContext` is left at whisper.cpp's default (false) — in validation it
    /// made no difference to the loop (window context wasn't the cause), and
    /// keeping context preserves cross-window coherence on long clips. The knobs
    /// are exposed (with the production defaults) only so tests can sweep them.
    public func transcribe(
        samples: [Float], language: String?, initialPrompt: String?, threads: Int32,
        noContext: Bool = false, entropyThreshold: Float = 3.0, temperatureIncrement: Float = 0.2
    ) throws -> String {
        guard let ctx else { throw WhisperCPPError.notInitialized }

        var params = Self.makeParams(
            threads: threads, noContext: noContext, entropyThreshold: entropyThreshold,
            temperatureIncrement: temperatureIncrement)

        // language and initial_prompt are borrowed C strings that must stay alive
        // across the whisper_full call, so bind them via nested withCString.
        func run(langPtr: UnsafePointer<CChar>?, promptPtr: UnsafePointer<CChar>?) throws -> String {
            params.language = langPtr
            params.initial_prompt = promptPtr
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

        func withLanguage(_ promptPtr: UnsafePointer<CChar>?) throws -> String {
            if let language {
                return try language.withCString { try run(langPtr: $0, promptPtr: promptPtr) }
            }
            return try run(langPtr: nil, promptPtr: promptPtr)
        }

        if let initialPrompt, !initialPrompt.isEmpty {
            return try initialPrompt.withCString { try withLanguage($0) }
        }
        return try withLanguage(nil)
    }
}
