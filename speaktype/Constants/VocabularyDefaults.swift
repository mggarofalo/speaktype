import Foundation

/// Default custom-vocabulary seed and registration.
///
/// The vocabulary is fed to Whisper as an "initial prompt" (previous-context
/// tokens), biasing the decoder toward spellings it would otherwise mangle —
/// proper nouns, product names, jargon, and colleagues' names.
///
/// The seed ships empty **by design**. It is a personal list by nature, so it
/// belongs in each user's own settings rather than in source control; a
/// previous version shipped one maintainer's real list in a public repo.
enum VocabularyDefaults {
    /// Intentionally empty. Users populate this in Settings → General.
    static let seed = ""

    /// Register as a UserDefaults *default* (not a write): edits persist
    /// normally, and clearing the field back to empty is respected because
    /// registered defaults only fill in when no value has ever been written.
    static func register() {
        UserDefaults.standard.register(defaults: ["customVocabulary": seed])
    }
}
