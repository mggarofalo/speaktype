import AVFoundation
import CoreML
import Foundation
import OSLog
import Tokenizers
import WhisperKit

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

    /// Alternate engine used when the `transcriptionEngine` default selects
    /// whisper.cpp (beta benchmarking). WhisperService owns the observable UI
    /// state and delegates the actual load/transcribe to this engine.
    private let cppEngine = WhisperCppEngine()

    /// Device RAM in GB (cached on init)
    static let deviceRAMGB: Int = {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }()

    enum TranscriptionError: Error, LocalizedError {
        case notInitialized
        case fileNotFound
        case alreadyLoading
        case loadingTimeout

        var errorDescription: String? {
            switch self {
            case .notInitialized: return "Model is not initialized"
            case .fileNotFound: return "Audio file not found"
            case .alreadyLoading: return "Model loading already in progress"
            case .loadingTimeout:
                return "Model loading timed out — your Mac may not have enough RAM for this model"
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

    // Init is internal to allow testing, but prefer using .shared in production
    init() {}

    // Default initialization (loads default or saved model)
    func initialize() async throws {
        try await loadModel(variant: currentModelVariant)
    }

    // Dynamic model loading with optimized WhisperKitConfig
    func loadModel(variant: String) async throws {
        // whisper.cpp engine path (beta benchmarking): auto-fetch the GGML model
        // and load it through the native backend. WhisperKit's pipe is unused here.
        if TranscriptionEngineSelection.current == .whispercpp {
            guard !isLoading else { throw TranscriptionError.alreadyLoading }
            isLoading = true
            isInitialized = false
            loadingStage = "Preparing whisper.cpp model..."
            do {
                let modelURL = try await WhisperCppModelStorage.ensureBenchmarkModel { progress in
                    self.loadingStage = "Downloading model… \(Int(progress * 100))%"
                }
                loadingStage = "Loading whisper.cpp model..."
                try await cppEngine.load(modelPath: modelURL.path)
                currentModelVariant = variant
                isInitialized = true
                isLoading = false
                loadingStage = ""
            } catch {
                isLoading = false
                loadingStage = ""
                throw error
            }
            return
        }

        // Already loaded this exact model
        if isInitialized && variant == currentModelVariant && pipe != nil {
            print("✅ Model \(variant) already loaded, skipping")
            return
        }

        // Prevent concurrent loading
        guard !isLoading else {
            print("⚠️ Model loading already in progress, skipping")
            throw TranscriptionError.alreadyLoading
        }

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

        isLoading = true
        isInitialized = false
        loadingStage = "Preparing model..."

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

            currentModelVariant = variant
            isInitialized = true
            isLoading = false
            loadingStage = ""
            print("✅ WhisperKit initialized and prewarmed with \(variant)")
        } catch {
            isLoading = false
            loadingStage = ""
            print(
                "❌ Failed to initialize WhisperKit with \(variant): \(error.localizedDescription)")
            throw error
        }
    }

    func transcribe(audioFile: URL, language: String = "auto") async throws -> String {
        // whisper.cpp engine path (beta benchmarking).
        if TranscriptionEngineSelection.current == .whispercpp {
            guard isInitialized else { throw TranscriptionError.notInitialized }
            guard FileManager.default.fileExists(atPath: audioFile.path) else {
                throw TranscriptionError.fileNotFound
            }
            isTranscribing = true
            defer { isTranscribing = false }
            return try await cppEngine.transcribe(audioFile: audioFile, language: language)
        }

        guard let pipe = pipe, isInitialized else {
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
