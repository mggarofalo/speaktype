import Foundation

/// Per-model spoken-language memory.
///
/// A single global language is wrong once you switch models: picking Spanish on
/// a multilingual model and then dropping to an English-only model used to
/// leave "Spanish" showing on a model that can only emit English, and switching
/// back lost the choice. Each model keeps its own selection, with the global
/// `transcriptionLanguage` retained as the fallback for models never set.
enum LanguagePreferences {
    static let mapKey = "transcriptionLanguageByModel"
    static let globalKey = "transcriptionLanguage"

    static let autoCode = "auto"
    static let englishCode = "en"

    // MARK: - Stored selection

    private static func map() -> [String: String] {
        guard let raw = UserDefaults.standard.string(forKey: mapKey),
            let data = raw.data(using: .utf8),
            let decoded = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return decoded
    }

    private static func writeMap(_ value: [String: String]) {
        guard let data = try? JSONEncoder().encode(value),
            let raw = String(data: data, encoding: .utf8)
        else { return }
        UserDefaults.standard.set(raw, forKey: mapKey)
    }

    static var globalLanguage: String {
        UserDefaults.standard.string(forKey: globalKey) ?? autoCode
    }

    /// The language the UI should show for `variant`: its own selection if it
    /// has one, otherwise the global setting.
    static func storedLanguage(forModel variant: String) -> String {
        guard !variant.isEmpty else { return globalLanguage }
        return map()[variant] ?? globalLanguage
    }

    /// Records `code` for `variant` and mirrors it to the global setting, which
    /// stays the fallback for models that have never been set explicitly.
    static func setLanguage(_ code: String, forModel variant: String) {
        UserDefaults.standard.set(code, forKey: globalKey)
        guard !variant.isEmpty else { return }
        var current = map()
        current[variant] = code
        writeMap(current)
    }

    // MARK: - Resolution for the engine

    /// What to actually hand the transcriber for `variant`.
    ///
    /// English-only (.en) models get "en" rather than "auto": whisper.cpp emits
    /// English from them regardless, so asking it to auto-detect first is a
    /// pass that cannot change the outcome.
    static func effectiveLanguage(forModel variant: String) -> String {
        if isEnglishOnly(variant) { return englishCode }
        return storedLanguage(forModel: variant)
    }

    /// Whether the language selection has any effect on `variant`.
    static func isEnglishOnly(_ variant: String) -> Bool {
        AIModel.model(for: variant)?.isEnglishOnly ?? false
    }

    /// Human-readable name for an ISO code, falling back to the code itself for
    /// anything Whisper reports that the picker does not list.
    static func displayName(for code: String) -> String {
        if code == autoCode { return "Auto-detect" }
        return GeneralSettingsTab.whisperLanguages.first(where: { $0.code == code })?.name ?? code
    }
}
