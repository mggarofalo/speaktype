import AppKit
import XCTest
@testable import speaktype

@MainActor
final class QuitShortcutTests: XCTestCase {
    func testCommandQInSpeakTypePreservesCaptureForTermination() {
        XCTAssertTrue(AppDelegate.preservesRecordingForQuit(
            characters: "q", modifiers: .command, isApplicationActive: true))
        XCTAssertTrue(AppDelegate.preservesRecordingForQuit(
            characters: "Q", modifiers: [.command, .capsLock], isApplicationActive: true))
    }

    func testCommandQInAnotherAppStillCancelsModifierRecording() {
        XCTAssertFalse(AppDelegate.preservesRecordingForQuit(
            characters: "q", modifiers: .command, isApplicationActive: false))
    }

    func testOtherModifierCombinationsDoNotMasqueradeAsQuit() {
        for modifiers: NSEvent.ModifierFlags in [[], .control, [.command, .shift], [.command, .option]] {
            XCTAssertFalse(AppDelegate.preservesRecordingForQuit(
                characters: "q", modifiers: modifiers, isApplicationActive: true))
        }
        XCTAssertFalse(AppDelegate.preservesRecordingForQuit(
            characters: "c", modifiers: .command, isApplicationActive: true))
        XCTAssertFalse(AppDelegate.preservesRecordingForQuit(
            characters: nil, modifiers: .command, isApplicationActive: true))
    }
}
