import AVFoundation
import CoreML
import Foundation
import OSLog
import Tokenizers
import WhisperKit

/// Coalesces concurrent work for one key while rejecting a different request.
/// The shared task owns its cleanup so a waiter resuming late cannot clear a
/// newer operation, and cancelling a waiter does not cancel the shared work.
@MainActor
final class ModelLoadCoordinator {
    private struct ActiveLoad {
        let id: UUID
        let key: WhisperService.ModelLoadKey
        let task: Task<Void, Error>
    }

    private var activeLoad: ActiveLoad?

    func run(
        key: WhisperService.ModelLoadKey,
        operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        if let activeLoad {
            guard activeLoad.key == key else {
                throw WhisperService.TranscriptionError.alreadyLoading
            }
            try await activeLoad.task.value
            return
        }

        let id = UUID()
        let task = Task { @MainActor in
            defer { finish(id: id) }
            try await operation()
        }
        activeLoad = ActiveLoad(id: id, key: key, task: task)
        try await task.value
    }

    private func finish(id: UUID) {
        guard activeLoad?.id == id else { return }
        activeLoad = nil
    }
}

@Observable
class WhisperService {
    // Shared singleton instance - use this everywhere
    static let shared = WhisperService()
    private static let placeholderPatterns = [
        #"\[(?:BLANK_AUDIO|SILENCE)\]"#,
        #"<\|nospeech\|>"#,
        #"\[\s*S\s*\]"#,
    ]
    private static let noiseLabelTerms = [
        "applause",
        "background noise",
        "blank audio",
        "breathing",
        "cough",
        "coughing",
        "exhale",
        "heartbeat",
        "indistinct",
        "inaudible",
        "inhale",
        "laughing",
        "laughter",
        "loud noise",
        "muffled speech",
        "music",
        "noise",
        "silence",
        "sigh",
        "sighs",
        "sniffing",
        "static",
        "unclear speech",
        "unintelligible",
        "wind",
        "wind blowing",
        "wind noise",
    ]
    private static let bracketedNoisePattern: String = {
        let escaped = noiseLabelTerms.map(NSRegularExpression.escapedPattern(for:)).joined(
            separator: "|")
        return #"[\[\(]\s*(?:"# + escaped + #")\s*[\]\)]"#
    }()

    var pipe: WhisperKit?
    var isInitialized = false
    var isTranscribing = false
    var isLoading = false
    var loadingStage: String = ""  // Descriptive stage for UI

    var currentModelVariant: String = ""  // No default - must be explicitly set

    /// ISO code the last transcription actually decoded with. Meaningful mainly
    /// on auto-detect, where it is the model's guess and the only signal the
    /// user gets that a wrong guess — not bad audio — produced a bad transcript.
    var lastDetectedLanguage: String?

    /// Alternate engine used when the `transcriptionEngine` default selects
    /// whisper.cpp (beta benchmarking). WhisperService owns the observable UI
    /// state and delegates the actual load/transcribe to this engine.
    private let cppEngine = WhisperCppEngine()

    struct ModelLoadKey: Equatable {
        let engine: TranscriptionEngineKind
        let variant: String
    }

    typealias ModelLoader = @MainActor (TranscriptionEngineKind, String) async throws -> Void
    typealias EngineSelector = @MainActor () -> TranscriptionEngineKind

    private let loadCoordinator = ModelLoadCoordinator()
    private let modelLoader: ModelLoader?
    private let engineSelector: EngineSelector
    private var loadedModelKeys: [ModelLoadKey] = []
    private var activeModelKey: ModelLoadKey?

    /// Device RAM in GB (cached on init)
    static let deviceRAMGB: Int = {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }()

    enum TranscriptionError: Error, LocalizedError {
        case notInitialized
        case fileNotFound
        case alreadyLoading
        case loadingTimeout
        case modelNotDownloaded

        var errorDescription: String? {
            switch self {
            case .notInitialized: return "Model is not initialized"
            case .fileNotFound: return "Audio file not found"
            case .alreadyLoading: return "Model loading already in progress"
            case .loadingTimeout:
                return "Model loading timed out — your Mac may not have enough RAM for this model"
            case .modelNotDownloaded:
                return "Model not downloaded yet — download it from Settings → AI Models"
            }
        }
    }

    /// Compute-unit selection, overridable at runtime for benchmarking:
    ///   defaults write com.mggarofalo.speaktype debugComputeUnits cpuAndNeuralEngine
    /// Valid values: cpuAndGPU (default), cpuAndNeuralEngine, all, cpuOnly.
    static var computeUnitsName: String {
        UserDefaults.standard.string(forKey: "debugComputeUnits") ?? "cpuAndGPU"
    }

    static func resolvedComputeUnits() -> MLComputeUnits {
        switch computeUnitsName {
        case "cpuAndNeuralEngine": return .cpuAndNeuralEngine
        case "all": return .all
        case "cpuOnly": return .cpuOnly
        default: return .cpuAndGPU
        }
    }

    /// Audio duration in seconds, for real-time-factor (RTF) logging. Returns 0 on failure.
    private static func audioDuration(of url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        let rate = file.fileFormat.sampleRate
        return rate > 0 ? Double(file.length) / rate : 0
    }

    // Init is internal to allow testing, but prefer using .shared in production.
    // The loader seam lets tests exercise load coordination without loading a
    // multi-gigabyte model; production uses the concrete engines below.
    init(
        modelLoader: ModelLoader? = nil,
        engineSelector: @escaping EngineSelector = { TranscriptionEngineSelection.current }
    ) {
        self.modelLoader = modelLoader
        self.engineSelector = engineSelector
    }

    /// Tears down the whisper.cpp backend ahead of process exit. See
    /// `WhisperCppEngine.unload()` for why this is mandatory rather than tidy.
    ///
    /// `nonisolated` so AppKit's terminate handler can await it without needing
    /// the main actor, which is busy running the terminate-later run loop.
    nonisolated func shutdown() async {
        await cppEngine.unload()
    }

    // Default initialization (loads default or saved model)
    func initialize() async throws {
        try await loadModel(variant: currentModelVariant)
    }

    // Dynamic model loading with optimized WhisperKitConfig
    func loadModel(variant: String) async throws {
        // Capture the route once. A preference change while the model awaits
        // disk/framework work must not redirect this load midway through.
        let engine = engineSelector()
        let key = ModelLoadKey(engine: engine, variant: variant)

        try await loadCoordinator.run(key: key) { [self] in
            // Check the cache only after admission: another model may already
            // be queued even though its task has not invalidated readiness yet.
            if isLoaded(key) {
                activate(key)
                return
            }
            try await performLoad(key: key)
        }
    }

    /// Whether the selected engine is ready to transcribe with this exact
    /// model. Callers must use this instead of the legacy global state, which
    /// cannot distinguish two engines that use the same model variant.
    func isReadyToTranscribe(variant: String) -> Bool {
        let key = ModelLoadKey(engine: engineSelector(), variant: variant)
        return activeModelKey == key && isLoaded(key)
    }

    private func isLoaded(_ key: ModelLoadKey) -> Bool {
        guard loadedModelKeys.contains(key) else { return false }
        if modelLoader != nil { return true }

        switch key.engine {
        case .whispercpp:
            return true
        case .whisperkit, .mlx:
            return pipe != nil
        }
    }

    private func performLoad(key: ModelLoadKey) async throws {
        // Validate before invalidating a previously loaded model. Downloads are
        // handled by the model picker, never by the load/warmup operation.
        var cppModelURL: URL?
        if modelLoader == nil {
            switch key.engine {
            case .whispercpp:
                guard WhisperCppModelStorage.isDownloaded(variant: key.variant),
                    let url = WhisperCppModelStorage.modelURL(for: key.variant)
                else {
                    throw TranscriptionError.modelNotDownloaded
                }
                cppModelURL = url
            case .whisperkit, .mlx:
                guard FileManager.default.fileExists(
                    atPath: ModelStorage.modelFolderURL(variant: key.variant).path)
                else {
                    throw TranscriptionError.modelNotDownloaded
                }
            }
        }

        isLoading = true
        isInitialized = false
        activeModelKey = nil
        invalidateLoadedModel(for: key.engine)
        loadingStage = "Preparing model..."
        defer {
            isLoading = false
            loadingStage = ""
        }

        if let modelLoader {
            try await modelLoader(key.engine, key.variant)
        } else if let cppModelURL {
            loadingStage = "Loading whisper.cpp model..."
            try await cppEngine.load(modelPath: cppModelURL.path)
        } else {
            try await loadWhisperKit(variant: key.variant)
        }

        loadedModelKeys.append(key)
        activate(key)
    }

    private func activate(_ key: ModelLoadKey) {
        currentModelVariant = key.variant
        activeModelKey = key
        isInitialized = true
    }

    private func invalidateLoadedModel(for engine: TranscriptionEngineKind) {
        switch engine {
        case .whispercpp:
            loadedModelKeys.removeAll { $0.engine == .whispercpp }
        case .whisperkit, .mlx:
            // These routes currently share WhisperKit's single in-memory pipe.
            loadedModelKeys.removeAll { $0.engine == .whisperkit || $0.engine == .mlx }
        }
    }

    private func loadWhisperKit(variant: String) async throws {
        let ramGB = Self.deviceRAMGB
        print("🔄 Initializing WhisperKit with model: \(variant)...")
        print("💻 Device RAM: \(ramGB) GB")

        if let model = AIModel.availableModels.first(where: { $0.variant == variant }),
            ramGB < model.minimumRAMGB
        {
            print(
                "⚠️ WARNING: Model \(variant) recommends \(model.minimumRAMGB)GB+ RAM, device has \(ramGB)GB. Loading may fail or be very slow."
            )
        }

        // Release existing model to free memory
        if pipe != nil {
            print("🗑️ Releasing previous model from memory...")
            pipe = nil
        }

        do {
            let modelFolderPath = ModelStorage.modelFolderURL(variant: variant).path

            // Use WhisperKitConfig with optimized settings
            let config = WhisperKitConfig(
                model: variant,
                downloadBase: ModelStorage.baseURL,
                modelFolder: modelFolderPath,
                // GPU instead of the default Neural Engine: identical transcription
                // output, but skips CoreML's ANE specialization pass at load, which
                // dominates startup (measured 3m08s ANE vs 56s GPU end-to-end for
                // large-v3_turbo on an M2 Pro/Max). Overridable via the
                // `debugComputeUnits` default for benchmarking (see resolvedComputeUnits).
                computeOptions: ModelComputeOptions(
                    audioEncoderCompute: Self.resolvedComputeUnits(),
                    textDecoderCompute: Self.resolvedComputeUnits()
                ),
                verbose: false,
                logLevel: .error,
                prewarm: true,  // Built-in model specialization (replaces manual warmup)
                load: true,
                download: false  // Already downloaded via ModelDownloadService
            )

            loadingStage = "Loading AI model..."

            // Start a watchdog timer that will flag a timeout
            let loadStart = Date()

            pipe = try await WhisperKit(config)

            let loadDuration = Date().timeIntervalSince(loadStart)
            print("⏱️ Model loaded in \(String(format: "%.1f", loadDuration))s")
            AppLogger.transcription.info(
                "⏱️ Model \(variant, privacy: .public) loaded in \(String(format: "%.1f", loadDuration), privacy: .public)s [compute=\(Self.computeUnitsName, privacy: .public)]"
            )

            print("✅ WhisperKit initialized and prewarmed with \(variant)")
        } catch {
            print(
                "❌ Failed to initialize WhisperKit with \(variant): \(error.localizedDescription)")
            throw error
        }
    }

    func transcribe(audioFile: URL, language: String = "auto") async throws -> String {
        // Capture the route once and require the active model to belong to it.
        // A preference change must never send audio to a previously loaded
        // backend merely because the legacy global flag is still true.
        let engine = engineSelector()
        guard let activeModelKey,
            activeModelKey.engine == engine,
            isLoaded(activeModelKey)
        else {
            throw TranscriptionError.notInitialized
        }

        // whisper.cpp engine path (beta benchmarking).
        if engine == .whispercpp {
            guard FileManager.default.fileExists(atPath: audioFile.path) else {
                throw TranscriptionError.fileNotFound
            }
            isTranscribing = true
            defer { isTranscribing = false }
            // noContext: true — the engine reuses one persistent WhisperCPPContext
            // across recordings, and whisper.cpp's no_context=false default seeds
            // each whisper_full call's decoder prompt from the PREVIOUS call's
            // decoded tokens (prompt_past persists on the context's state between
            // calls). For independent push-to-talk dictations that carry-over
            // leaks one recording's transcript into the start of the next
            // (observed: "This is the kind of feedback…" bleeding across three
            // distinct clips). Clearing prompt_past per recording fixes it without
            // affecting within-clip cross-window coherence, which depends only on
            // tokens decoded inside the current call, not on no_context.
            let output = try await cppEngine.transcribe(
                audioFile: audioFile, language: language,
                noContext: WhisperCppTuning.noContext,
                entropyThreshold: WhisperCppTuning.entropyThreshold,
                temperatureIncrement: WhisperCppTuning.temperatureIncrement)
            lastDetectedLanguage = output.languageCode
            return output.text
        }

        guard let pipe = pipe else {
            throw TranscriptionError.notInitialized
        }

        guard FileManager.default.fileExists(atPath: audioFile.path) else {
            throw TranscriptionError.fileNotFound
        }

        isTranscribing = true
        defer { isTranscribing = false }

        print("Starting transcription for: \(audioFile.lastPathComponent)")

        do {
            let options = decodingOptions(for: language)
            let inferStart = Date()
            let results = try await pipe.transcribe(audioPath: audioFile.path, decodeOptions: options)
            let inferDuration = Date().timeIntervalSince(inferStart)
            let audioSeconds = Self.audioDuration(of: audioFile)
            let rtf = audioSeconds > 0 ? inferDuration / audioSeconds : 0
            AppLogger.transcription.info(
                "⏱️ Transcribed \(String(format: "%.1f", audioSeconds), privacy: .public)s audio in \(String(format: "%.2f", inferDuration), privacy: .public)s (RTF \(String(format: "%.2f", rtf), privacy: .public)) [compute=\(Self.computeUnitsName, privacy: .public)]"
            )
            let text = Self.normalizedTranscription(
                from: results.map { $0.text }.joined(separator: " "))
            lastDetectedLanguage = results.first?.language

            print("Transcription complete: \(text.prefix(50))...")
            return text
        } catch {
            print("Transcription failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Transcribe a background audio chunk without affecting the global `isTranscribing` flag.
    /// Chunk files are automatically deleted after transcription.
    func transcribeChunk(audioFile: URL, language: String = "auto") async throws -> String {
        guard let pipe = pipe, isInitialized else {
            throw TranscriptionError.notInitialized
        }

        guard FileManager.default.fileExists(atPath: audioFile.path) else {
            // Chunk file may have been cleaned up already - return empty gracefully
            return ""
        }

        print("🔪 Chunk transcription started: \(audioFile.lastPathComponent)")

        let results = try await pipe.transcribe(
            audioPath: audioFile.path,
            decodeOptions: decodingOptions(for: language)
        )
        let text = Self.normalizedTranscription(from: results.map { $0.text }.joined(separator: " "))

        print("🔪 Chunk done: \(text.prefix(40))...")
        // Clean up temp chunk file after transcription
        try? FileManager.default.removeItem(at: audioFile)
        return text
    }

    private func decodingOptions(for language: String) -> DecodingOptions {
        Self.decodingOptions(language: language, promptTokens: vocabularyPromptTokens())
    }

    static func decodingOptions(language: String, promptTokens: [Int]?) -> DecodingOptions {
        var options = DecodingOptions()
        options.task = .transcribe
        options.language = (language == "auto") ? nil : language
        // Long clips (>30s) are decoded as sequential 30s windows that carry the
        // prior window's tokens forward as prompt context. If one window slips
        // into a repetition loop, that looped text re-seeds the next window and
        // the loop cascades for the rest of the recording — WhisperKit's
        // per-window compressionRatio/temperature fallbacks can't break out once
        // the carried prompt keeps re-seeding it. VAD chunking splits at silence
        // and transcribes each chunk independently (no prompt carry-over), so a
        // degenerate window stays contained; it also lets long clips decode
        // concurrently. Short clips are a single chunk and unaffected.
        options.chunkingStrategy = .vad
        if let promptTokens {
            options.promptTokens = promptTokens
            // Prompt conditioning lowers the decoder's confidence in the first
            // sampled token, tripping WhisperKit's firstTokenLogProbThreshold
            // (-1.5 default), which aborts the window with zero tokens — every
            // dictation came back "No speech detected". Verified against a real
            // recording: identical audio transcribes correctly with the
            // threshold disabled and returns empty with it on.
            options.firstTokenLogProbThreshold = nil
        }
        return options
    }

    /// Whisper "initial prompt" conditioning: the user's custom vocabulary is
    /// encoded as previous-context tokens, biasing the decoder toward those
    /// spellings (proper nouns, product names, coworker names). WhisperKit
    /// trims the prompt to the max context and strips special tokens itself.
    private func vocabularyPromptTokens() -> [Int]? {
        guard
            let prompt = Self.vocabularyPrompt(
                from: UserDefaults.standard.string(forKey: "customVocabulary") ?? ""),
            let tokenizer = pipe?.tokenizer
        else { return nil }

        let tokens = tokenizer.encode(text: prompt)
        return tokens.isEmpty ? nil : tokens
    }

    /// Builds the glossary prompt string from the raw vocabulary setting
    /// (comma- or newline-separated terms). Returns nil when no terms remain.
    static func vocabularyPrompt(from rawVocabulary: String) -> String? {
        let terms = rawVocabulary
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !terms.isEmpty else { return nil }

        // Phrased as natural prior context — biases better than a bare list.
        return " Glossary: " + terms.joined(separator: ", ") + "."
    }

    /// Filler words removed when the "Remove filler words" setting is on.
    /// Word-boundary anchored so e.g. "ahead" or "umbrella" are never touched;
    /// a trailing comma/period left behind by the filler is consumed with it.
    private static let fillerWordPattern = #"(?i)\b(?:um+|uh+|erm+|hmm+|mhm+)\b[,.]?"#

    static func normalizedTranscription(
        from rawText: String,
        removeFillerWords: Bool = UserDefaults.standard.bool(forKey: "removeFillerWords")
    ) -> String {
        var normalized = rawText

        for pattern in placeholderPatterns {
            normalized = normalized.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }

        normalized = normalized.replacingOccurrences(
            of: bracketedNoisePattern,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )

        if removeFillerWords {
            normalized = normalized.replacingOccurrences(
                of: fillerWordPattern,
                with: " ",
                options: .regularExpression
            )
            // A filler at the start of a sentence can leave a stranded
            // lowercase start or " ," artifacts; collapse leftover punctuation.
            normalized = normalized.replacingOccurrences(
                of: #"\s+([,.])"#,
                with: "$1",
                options: .regularExpression
            )
        }

        normalized = normalized.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )

        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
