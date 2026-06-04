import Foundation

/// Default custom-vocabulary seed and registration.
///
/// The vocabulary is fed to Whisper as an "initial prompt" (previous-context
/// tokens), biasing the decoder toward these spellings — proper nouns the
/// model would otherwise mangle ("Spryng" → "spring", "Resolv360" →
/// "resolve 360", coworker names, product names).
enum VocabularyDefaults {
    /// Seeded for Michael's environment; fully editable in Settings.
    static let seed = """
        i3 Verticals, Justice Tech, CourtOne Jury, GovRec, Resolv360, Spryng, \
        Midas, WebJury, Abacus, iTicket, Krunal Mehta, Vishal, Ryan Foley, \
        Alesha Gorton, Johnathan Hernandez, Ronibe Ekhator, Ram Ganesan, \
        Dustin Ballard, Miles Maddox, Brian Hooper, Denis Zamorski, \
        Jason Kopish, Hardik Ladva, Nancy Karnani, Jatin, Sunil, Apexa, \
        Garofalo, Jira, Confluence, Bitbucket, Blazor, Aspire, Terraform, \
        MudBlazor, WhisperKit, Anthropic, Claude
        """

    /// Register as a UserDefaults *default* (not a write): the user sees the
    /// seed immediately, edits persist normally, and clearing the field back
    /// to empty is respected because registered defaults only fill in when
    /// no value has ever been written.
    static func register() {
        UserDefaults.standard.register(defaults: ["customVocabulary": seed])
    }
}
