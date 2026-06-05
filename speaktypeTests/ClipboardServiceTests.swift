import XCTest
@testable import speaktype

/// Recording fake for the pasteboard seam. Models the one behavior the
/// preservation logic depends on: every write bumps `changeCount`, exactly as
/// the system pasteboard does. State (`items`) is a deep copy by value, matching
/// the snapshot semantics of the real pasteboard.
@MainActor
final class FakePasteboard: PasteboardAccessing {
    private(set) var items: [[String: Data]] = []
    private(set) var changeCount: Int = 0

    /// Simulate an external writer (the user copying something) without going
    /// through the seam's own write methods — bumps changeCount like the system.
    func simulateExternalWrite(string: String) {
        items = [[NSPasteboard.PasteboardType.string.rawValue: Data(string.utf8)]]
        changeCount += 1
    }

    /// Seed initial contents and bump changeCount once, modelling "the user
    /// already had this on the clipboard" without going through the seam.
    func seed(_ snapshot: [[String: Data]]) {
        items = snapshot
        changeCount += 1
    }

    var currentString: String? {
        guard let data = items.first?[NSPasteboard.PasteboardType.string.rawValue] else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: PasteboardAccessing

    func readSnapshot() -> [[String: Data]]? {
        items.isEmpty ? nil : items
    }

    func readString() -> String? {
        currentString
    }

    func write(string: String) {
        items = [[NSPasteboard.PasteboardType.string.rawValue: Data(string.utf8)]]
        changeCount += 1
    }

    func write(snapshot: [[String: Data]]) {
        items = snapshot
        changeCount += 1
    }

    func clear() {
        items = []
        changeCount += 1
    }
}

@MainActor
final class ClipboardServiceTests: XCTestCase {

    private let stringType = NSPasteboard.PasteboardType.string.rawValue

    private func makeService() -> (ClipboardService, FakePasteboard) {
        let fake = FakePasteboard()
        return (ClipboardService(pasteboard: fake), fake)
    }

    // MARK: copy(text:)

    func testCopyWritesStringThroughPasteboard() {
        let (service, fake) = makeService()

        service.copy(text: "Copied Text Check")

        XCTAssertEqual(fake.currentString, "Copied Text Check")
    }

    // MARK: copyTranscriptPreservingClipboard

    func testCopyTranscriptPreservingClipboardWritesTranscript() {
        let (service, fake) = makeService()
        fake.simulateExternalWrite(string: "user's prior content")

        service.copyTranscriptPreservingClipboard("the transcript")

        XCTAssertEqual(fake.currentString, "the transcript",
                       "the transcript should be on the pasteboard after the preserving copy")
    }

    func testCopyTranscriptPreservingClipboardThenRestoreReturnsPriorContent() {
        let (service, fake) = makeService()
        fake.simulateExternalWrite(string: "user's prior content")

        service.copyTranscriptPreservingClipboard("the transcript")
        // Nothing else wrote since our transcript copy.
        service.restorePreservedClipboard()

        XCTAssertEqual(fake.currentString, "user's prior content",
                       "the user's original clipboard should be restored when nothing wrote in between")
    }

    // MARK: restorePreservedClipboard — changeCount gating

    func testRestoreSkippedWhenClipboardChangedSinceTranscriptCopy() {
        let (service, fake) = makeService()
        fake.simulateExternalWrite(string: "user's prior content")
        service.copyTranscriptPreservingClipboard("the transcript")

        // User copies something new after the transcript landed.
        fake.simulateExternalWrite(string: "something newer")

        service.restorePreservedClipboard()

        XCTAssertEqual(fake.currentString, "something newer",
                       "newer user content must not be clobbered by the restore")
    }

    func testRestoreClearsPreservedStateWhenChangeCountDiffers() {
        let (service, fake) = makeService()
        fake.simulateExternalWrite(string: "user's prior content")
        service.copyTranscriptPreservingClipboard("the transcript")
        fake.simulateExternalWrite(string: "something newer")

        // First restore is skipped (changeCount differs); per the defer it must
        // still clear the preserved snapshot. A second restore then hits the
        // "nothing preserved" early return and must not touch the pasteboard.
        service.restorePreservedClipboard()
        let stateAfterSkip = fake.currentString
        let changeCountAfterSkip = fake.changeCount

        service.restorePreservedClipboard()

        XCTAssertEqual(fake.currentString, stateAfterSkip,
                       "second restore must be a no-op — preserved state was cleared by the skipped restore")
        XCTAssertEqual(fake.changeCount, changeCountAfterSkip,
                       "second restore must not write to the pasteboard")
    }

    func testRestoreWithNothingPreservedIsNoOp() {
        let (service, fake) = makeService()
        fake.simulateExternalWrite(string: "untouched content")
        let changeCountBefore = fake.changeCount

        service.restorePreservedClipboard()

        XCTAssertEqual(fake.currentString, "untouched content")
        XCTAssertEqual(fake.changeCount, changeCountBefore,
                       "restore with no saved snapshot must not write to the pasteboard")
    }

    func testSecondRestoreAfterSuccessIsNoOp() {
        let (service, fake) = makeService()
        fake.simulateExternalWrite(string: "user's prior content")
        service.copyTranscriptPreservingClipboard("the transcript")
        service.restorePreservedClipboard()

        // After a successful restore the pasteboard holds the prior content.
        let changeCountAfterFirstRestore = fake.changeCount

        service.restorePreservedClipboard()

        XCTAssertEqual(fake.currentString, "user's prior content")
        XCTAssertEqual(fake.changeCount, changeCountAfterFirstRestore,
                       "state was cleared by the first restore — the second must be a no-op")
    }

    // MARK: snapshot fidelity

    func testRestorePreservesMultiTypeContent() {
        let (service, fake) = makeService()
        let htmlType = NSPasteboard.PasteboardType.html.rawValue
        let original: [[String: Data]] = [[
            stringType: Data("plain text".utf8),
            htmlType: Data("<b>rich</b>".utf8),
        ]]
        fake.seed(original)

        service.copyTranscriptPreservingClipboard("the transcript")
        service.restorePreservedClipboard()

        XCTAssertEqual(fake.items.count, 1, "single item restored")
        XCTAssertEqual(fake.items.first?[stringType], Data("plain text".utf8),
                       "string type restored byte-for-byte")
        XCTAssertEqual(fake.items.first?[htmlType], Data("<b>rich</b>".utf8),
                       "html type restored byte-for-byte")
    }

    func testRestorePreservesMultipleItems() {
        let (service, fake) = makeService()
        let original: [[String: Data]] = [
            [stringType: Data("first".utf8)],
            [stringType: Data("second".utf8)],
        ]
        fake.seed(original)

        service.copyTranscriptPreservingClipboard("the transcript")
        service.restorePreservedClipboard()

        XCTAssertEqual(fake.items.count, 2, "both items restored")
        XCTAssertEqual(fake.items[0][stringType], Data("first".utf8))
        XCTAssertEqual(fake.items[1][stringType], Data("second".utf8))
    }
}
