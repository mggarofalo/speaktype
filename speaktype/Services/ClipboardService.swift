import ApplicationServices
import Cocoa

/// Side-effect boundary for the system pasteboard. The production conformance
/// wraps `NSPasteboard.general`; tests substitute a recording fake so the
/// clipboard-preservation decision logic can be exercised without touching the
/// real pasteboard.
///
/// A snapshot is a deep copy of the pasteboard's contents: an array of items,
/// each a map from pasteboard type (raw string) to its raw `Data`. This shape
/// preserves the original deep-copy semantics — pasteboard items become invalid
/// once the pasteboard is cleared, so the data must be captured by value, not
/// held as live `NSPasteboardItem` references.
protocol PasteboardAccessing {
    /// Monotonic counter the system bumps on every write; used to detect whether
    /// anything wrote to the pasteboard since our own write.
    var changeCount: Int { get }
    /// Deep copy of the current pasteboard contents (nil if the pasteboard is empty).
    func readSnapshot() -> [[String: Data]]?
    /// Current plain-text contents, if any.
    func readString() -> String?
    /// Clear the pasteboard and write a plain string.
    func write(string: String)
    /// Clear the pasteboard and restore a previously captured snapshot.
    func write(snapshot: [[String: Data]])
    /// Clear the pasteboard, leaving it empty.
    func clear()
}

class ClipboardService {
    static let shared = ClipboardService()

    private let pasteboard: PasteboardAccessing

    init(pasteboard: PasteboardAccessing = SystemPasteboard()) {
        self.pasteboard = pasteboard
    }

    // The project defaults to MainActor isolation, which would give this type a
    // main-actor-isolated deinit. There is no main-actor state to tear down, and
    // the back-deployed main-actor deinit path crashes when a non-`shared`
    // instance is released under test. A nonisolated deinit avoids that hop.
    nonisolated deinit {}

    // Snapshot of the user's pasteboard taken before a transient transcript
    // copy, plus the changeCount of our own write so we can tell whether the
    // user copied something new in the meantime.
    private var savedPasteboardItems: [[String: Data]]?
    private var transcriptChangeCount: Int = -1

    // Copy text to system clipboard
    func copy(text: String) {
        pasteboard.write(string: text)

        // Verify write
        if let check = pasteboard.readString(), check == text {
            print("✅ Clipboard Write Verified: '\(check.prefix(20))...'")
        } else {
            print("❌ Clipboard Write FAILED!")
        }
    }

    /// Copy the transcript while remembering whatever the user had on the
    /// pasteboard, so it can be put back after the auto-paste (#62 upstream:
    /// dictation should not wipe out the user's clipboard).
    func copyTranscriptPreservingClipboard(_ text: String) {
        // Deep-copy the current items — pasteboard items become invalid once
        // the pasteboard is cleared, so the data must be captured now.
        savedPasteboardItems = pasteboard.readSnapshot()

        copy(text: text)
        transcriptChangeCount = pasteboard.changeCount
    }

    /// Restore the pasteboard saved by `copyTranscriptPreservingClipboard`,
    /// unless the user (or another app) has written to the pasteboard since
    /// our transcript copy — never clobber newer content.
    func restorePreservedClipboard() {
        defer {
            savedPasteboardItems = nil
            transcriptChangeCount = -1
        }

        guard let saved = savedPasteboardItems else { return }

        guard pasteboard.changeCount == transcriptChangeCount else {
            print("ℹ️ Clipboard changed since transcript copy — skipping restore")
            return
        }

        // Mirrors the original: clear unconditionally, then write only when the
        // snapshot is non-empty (writeObjects rejects an empty array). The
        // production conformance clears inside write(snapshot:); an empty
        // snapshot is cleared explicitly here so restoring "nothing" leaves the
        // pasteboard empty rather than retaining the transcript.
        if saved.isEmpty {
            pasteboard.clear()
        } else {
            pasteboard.write(snapshot: saved)
        }
        print("✅ Restored previous clipboard contents")
    }

    // Paste content (Simulate Cmd+V)
    func paste() {
        // Create a concurrent task to avoid blocking main thread if needed,
        // though CGEvent is fast.
        DispatchQueue.main.async {
            let source = CGEventSource(stateID: .hidSystemState)

            // Command key down
            let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true)
            cmdDown?.flags = .maskCommand

            // 'V' key down
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
            vDown?.flags = .maskCommand

            // 'V' key up
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
            vUp?.flags = .maskCommand

            // Command key up
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false)

            // Post events
            cmdDown?.post(tap: .cghidEventTap)
            vDown?.post(tap: .cghidEventTap)
            vUp?.post(tap: .cghidEventTap)
            cmdUp?.post(tap: .cghidEventTap)

            print("Simulated Cmd+V")
        }
    }

    // Fallback using AppleScript (more robust for some apps)
    func appleScriptPaste() {
        let script = "tell application \"System Events\" to keystroke \"v\" using command down"
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                print("AppleScript Paste Error: \(error)")
            } else {
                print("Executed AppleScript Paste")
            }
        }
    }

    // Check if we have permission to send keystrokes
    var isAccessibilityTrusted: Bool {
        return AXIsProcessTrusted()
    }

    // Request permission via system prompt
    func requestAccessibilityPermission() {
        let options =
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

/// Production conformance: the original `NSPasteboard.general` code, verbatim.
struct SystemPasteboard: PasteboardAccessing {
    var changeCount: Int {
        NSPasteboard.general.changeCount
    }

    func readSnapshot() -> [[String: Data]]? {
        NSPasteboard.general.pasteboardItems?.map { item in
            var captured: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    captured[type.rawValue] = data
                }
            }
            return captured
        }
    }

    func readString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    func write(string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    func write(snapshot: [[String: Data]]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = snapshot.map { captured in
            let item = NSPasteboardItem()
            for (rawType, data) in captured {
                item.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

    func clear() {
        NSPasteboard.general.clearContents()
    }
}
