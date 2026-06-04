import ApplicationServices
import Cocoa

class ClipboardService {
    static let shared = ClipboardService()

    private init() {}

    // Snapshot of the user's pasteboard taken before a transient transcript
    // copy, plus the changeCount of our own write so we can tell whether the
    // user copied something new in the meantime.
    private var savedPasteboardItems: [NSPasteboardItem]?
    private var transcriptChangeCount: Int = -1

    // Copy text to system clipboard
    func copy(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Verify write
        if let check = pasteboard.string(forType: .string), check == text {
            print("✅ Clipboard Write Verified: '\(check.prefix(20))...'")
        } else {
            print("❌ Clipboard Write FAILED!")
        }
    }

    /// Copy the transcript while remembering whatever the user had on the
    /// pasteboard, so it can be put back after the auto-paste (#62 upstream:
    /// dictation should not wipe out the user's clipboard).
    func copyTranscriptPreservingClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general

        // Deep-copy the current items — pasteboard items become invalid once
        // the pasteboard is cleared, so the data must be captured now.
        savedPasteboardItems = pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }

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

        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount == transcriptChangeCount else {
            print("ℹ️ Clipboard changed since transcript copy — skipping restore")
            return
        }

        pasteboard.clearContents()
        if !saved.isEmpty {
            pasteboard.writeObjects(saved)
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
