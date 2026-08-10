import Foundation

/// User-tunable whisper.cpp decode parameters.
///
/// These were hardcoded at the values validated against real dictations. They
/// are exposed because multilingual accuracy is workload-dependent and the
/// right trade-off differs per speaker and language — but every default here is
/// the validated one, and `isDefault` lets the UI offer a one-click way back.
enum WhisperCppTuning {
    enum Key {
        static let entropyThreshold = "whisperCppEntropyThreshold"
        static let temperatureIncrement = "whisperCppTemperatureIncrement"
        static let carryContext = "whisperCppCarryContext"
    }

    /// Up from whisper.cpp's own 2.4. A 146s dictation degenerated into one
    /// phrase repeated to the end; 3.0 collapsed a 21× repeated 5-gram back to
    /// 1× while leaving short clips byte-identical.
    static let defaultEntropyThreshold: Double = 3.0

    /// Drives the temperature fallback that re-decodes a low-entropy (looping)
    /// segment instead of emitting it. 0 disables the fallback entirely.
    static let defaultTemperatureIncrement: Double = 0.2

    /// Off by default, i.e. whisper.cpp's `no_context = true`.
    ///
    /// The engine reuses one persistent context across recordings, and
    /// whisper.cpp seeds each decode's prompt from the PREVIOUS call's tokens.
    /// For independent push-to-talk dictations that leaks one recording's
    /// transcript into the start of the next. Turning this on restores the
    /// carry-over; it does not affect within-clip coherence, which depends only
    /// on tokens decoded inside the current call.
    static let defaultCarryContext: Bool = false

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.entropyThreshold: defaultEntropyThreshold,
            Key.temperatureIncrement: defaultTemperatureIncrement,
            Key.carryContext: defaultCarryContext,
        ])
    }

    /// Clamped to a sane band so a typo in `defaults write` cannot wedge
    /// transcription. The upper entropy bound is deliberately generous; past
    /// ~4 the decoder starts rejecting valid speech.
    static var entropyThreshold: Float {
        let raw = UserDefaults.standard.double(forKey: Key.entropyThreshold)
        guard raw > 0 else { return Float(defaultEntropyThreshold) }
        return Float(min(max(raw, 0.5), 6.0))
    }

    static var temperatureIncrement: Float {
        let raw = UserDefaults.standard.double(forKey: Key.temperatureIncrement)
        return Float(min(max(raw, 0.0), 1.0))
    }

    static var carryContext: Bool {
        UserDefaults.standard.bool(forKey: Key.carryContext)
    }

    /// `whisper_full_params.no_context` — the inverse of the user-facing toggle.
    static var noContext: Bool { !carryContext }

    static var isDefault: Bool {
        abs(Double(entropyThreshold) - defaultEntropyThreshold) < 0.0001
            && abs(Double(temperatureIncrement) - defaultTemperatureIncrement) < 0.0001
            && carryContext == defaultCarryContext
    }

    static func resetToDefaults() {
        UserDefaults.standard.set(defaultEntropyThreshold, forKey: Key.entropyThreshold)
        UserDefaults.standard.set(defaultTemperatureIncrement, forKey: Key.temperatureIncrement)
        UserDefaults.standard.set(defaultCarryContext, forKey: Key.carryContext)
    }
}
