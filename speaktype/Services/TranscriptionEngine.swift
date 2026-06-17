import Foundation

/// Which speech-to-text backend powers transcription. Selected at runtime via
/// the `transcriptionEngine` UserDefaults key; beta builds expose a picker so
/// engines can be benchmarked head-to-head on the same machine and audio.
enum TranscriptionEngineKind: String, CaseIterable {
    case whisperkit
    case whispercpp
    case mlx

    var displayName: String {
        switch self {
        case .whisperkit: return "WhisperKit (CoreML)"
        case .whispercpp: return "whisper.cpp (Metal)"
        case .mlx: return "MLX"
        }
    }
}

/// The transcription surface every engine implements. Mirrors the API the
/// SwiftUI views already call on `WhisperService.shared`, so a future engine
/// can be swapped in without touching callers.
///
/// `transcribeChunk` is intentionally excluded — it is an unused streaming stub
/// and not part of the live call path.
protocol TranscriptionEngine: AnyObject {
    var isInitialized: Bool { get }
    var isLoading: Bool { get }
    var isTranscribing: Bool { get }
    var loadingStage: String { get }
    var currentModelVariant: String { get }

    func initialize() async throws
    func loadModel(variant: String) async throws
    func transcribe(audioFile: URL, language: String) async throws -> String
}

/// Resolves the currently selected engine from UserDefaults, defaulting to
/// WhisperKit (the production engine) when unset or unrecognized.
enum TranscriptionEngineSelection {
    static let defaultsKey = "transcriptionEngine"

    /// whisper.cpp (Metal) is the production default — ~10–15× faster than
    /// WhisperKit/CoreML for the same model on Apple Silicon. Registered as a
    /// fallback so an unset key resolves to whisper.cpp while still letting the
    /// user pick WhisperKit explicitly.
    static let defaultKind: TranscriptionEngineKind = .whispercpp

    static func registerDefault() {
        UserDefaults.standard.register(defaults: [defaultsKey: defaultKind.rawValue])
    }

    static var current: TranscriptionEngineKind {
        guard
            let raw = UserDefaults.standard.string(forKey: defaultsKey),
            let kind = TranscriptionEngineKind(rawValue: raw)
        else {
            return defaultKind
        }
        return kind
    }
}

// WhisperService already implements this surface; declaring conformance lets
// callers treat it polymorphically once alternate engines exist.
extension WhisperService: TranscriptionEngine {}
