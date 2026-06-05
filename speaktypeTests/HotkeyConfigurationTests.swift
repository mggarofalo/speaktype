import Carbon.HIToolbox
import XCTest
@testable import speaktype

final class HotkeyConfigurationTests: XCTestCase {

    // MARK: - isValid

    func testIsValidRequiresAtLeastOneModifier() {
        let noModifiers = HotkeyConfiguration(
            keyCode: UInt32(kVK_ANSI_A),
            modifierFlags: []
        )
        XCTAssertFalse(noModifiers.isValid)

        let withModifier = HotkeyConfiguration(
            keyCode: UInt32(kVK_ANSI_A),
            modifierFlags: [.command]
        )
        XCTAssertTrue(withModifier.isValid)
    }

    func testDefaultConfigurationsAreValid() {
        XCTAssertTrue(HotkeyConfiguration.default.isValid)
        XCTAssertTrue(HotkeyConfiguration.alternativeOne.isValid)
        XCTAssertTrue(HotkeyConfiguration.alternativeTwo.isValid)
    }

    // MARK: - conflictsWithSystemShortcuts

    func testConflictsWithSystemShortcutsDetectsCommandV() {
        let paste = HotkeyConfiguration(
            keyCode: UInt32(kVK_ANSI_V),
            modifierFlags: [.command]
        )
        XCTAssertTrue(paste.conflictsWithSystemShortcuts)
    }

    func testConflictsWithSystemShortcutsDetectsCommandSpaceSpotlight() {
        let spotlight = HotkeyConfiguration(
            keyCode: UInt32(kVK_Space),
            modifierFlags: [.command]
        )
        XCTAssertTrue(spotlight.conflictsWithSystemShortcuts)
    }

    func testConflictsWithSystemShortcutsAllowsNonConflictingChord() {
        // Control+Shift+Space (the default) is not in the conflict table.
        let safe = HotkeyConfiguration(
            keyCode: UInt32(kVK_Space),
            modifierFlags: [.control, .shift]
        )
        XCTAssertFalse(safe.conflictsWithSystemShortcuts)
    }

    func testConflictsRequiresExactModifierMatch() {
        // ⌘⇧V is not the same chord as the conflicting ⌘V — adding a modifier
        // must NOT register as a conflict.
        let shiftedPaste = HotkeyConfiguration(
            keyCode: UInt32(kVK_ANSI_V),
            modifierFlags: [.command, .shift]
        )
        XCTAssertFalse(shiftedPaste.conflictsWithSystemShortcuts)
    }

    // MARK: - description formatting

    func testDescriptionRendersModifierSymbolsInCanonicalOrder() {
        let config = HotkeyConfiguration(
            keyCode: UInt32(kVK_ANSI_V),
            modifierFlags: [.command, .shift]
        )
        // Order is fixed by the implementation: ⌃ ⌥ ⇧ ⌘, then the key.
        XCTAssertEqual(config.description, "⇧⌘V")
    }

    func testDescriptionRendersAllModifiersAndNamedKey() {
        let config = HotkeyConfiguration(
            keyCode: UInt32(kVK_Space),
            modifierFlags: [.control, .option, .shift, .command]
        )
        XCTAssertEqual(config.description, "⌃⌥⇧⌘Space")
    }

    func testDescriptionRendersArrowKeySymbol() {
        let config = HotkeyConfiguration(
            keyCode: UInt32(kVK_LeftArrow),
            modifierFlags: [.command]
        )
        XCTAssertEqual(config.description, "⌘←")
    }

    func testDescriptionFallsBackToHexForUnknownKey() {
        // 0x6E is a key with no entry in the mapping table.
        let config = HotkeyConfiguration(
            keyCode: 0x6E,
            modifierFlags: [.control]
        )
        XCTAssertEqual(config.description, "⌃Key6E")
    }

    // MARK: - Carbon modifier flag conversion

    func testCarbonFlagsForSingleModifier() {
        XCTAssertEqual(ModifierFlags.command.carbonFlags, UInt32(cmdKey))
        XCTAssertEqual(ModifierFlags.shift.carbonFlags, UInt32(shiftKey))
        XCTAssertEqual(ModifierFlags.option.carbonFlags, UInt32(optionKey))
        XCTAssertEqual(ModifierFlags.control.carbonFlags, UInt32(controlKey))
    }

    func testCarbonFlagsForEmptyIsZero() {
        XCTAssertEqual(ModifierFlags([]).carbonFlags, 0)
    }

    func testCarbonFlagsCombinesModifiers() {
        let combined: ModifierFlags = [.command, .shift]
        XCTAssertEqual(combined.carbonFlags, UInt32(cmdKey) | UInt32(shiftKey))
    }

    // MARK: - Cocoa modifier flag conversion

    func testCocoaFlagsForSingleModifier() {
        XCTAssertEqual(ModifierFlags.command.cocoaFlags, 1 << 20)
        XCTAssertEqual(ModifierFlags.shift.cocoaFlags, 1 << 17)
        XCTAssertEqual(ModifierFlags.option.cocoaFlags, 1 << 19)
        XCTAssertEqual(ModifierFlags.control.cocoaFlags, 1 << 18)
    }

    func testCocoaFlagsForEmptyIsZero() {
        XCTAssertEqual(ModifierFlags([]).cocoaFlags, 0)
    }

    func testCocoaFlagsCombinesModifiers() {
        let combined: ModifierFlags = [.control, .command]
        XCTAssertEqual(combined.cocoaFlags, (1 << 18) | (1 << 20))
    }
}
