import Foundation
import KeyboardShortcuts
import AppKit

extension KeyboardShortcuts.Name {
    static let toggleRecord = Self("toggleRecord", default: .init(.space, modifiers: [.control, .option]))

    /// User-recorded chord (modifier + key, e.g. ⌃V) used when the hotkey
    /// selection is `HotkeyOption.chord`. No default — the user records one
    /// in Settings. Carbon consumes the chord globally while enabled, so it
    /// never reaches the focused app.
    static let dictationChord = Self("dictationChord")
}

extension Notification.Name {
    static let hotkeyTriggered = Notification.Name("hotkeyTriggered") // Legacy, can be removed
    static let recordingStartRequested = Notification.Name("recordingStartRequested")
    static let recordingStopRequested = Notification.Name("recordingStopRequested")
    static let recordingCancelRequested = Notification.Name("recordingCancelRequested")
}
