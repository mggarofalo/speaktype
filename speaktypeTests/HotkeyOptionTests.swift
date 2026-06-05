import AppKit
import SwiftUI
import XCTest
@testable import speaktype

final class HotkeyOptionTests: XCTestCase {

    // MARK: - Raw value round-trip

    func testRawValueRoundTripForAllCases() {
        for option in HotkeyOption.allCases {
            let restored = HotkeyOption(rawValue: option.rawValue)
            XCTAssertEqual(restored, option, "raw value round-trip failed for \(option)")
        }
    }

    func testInitFromUnknownRawValueReturnsNil() {
        XCTAssertNil(HotkeyOption(rawValue: "notAHotkey"))
        XCTAssertNil(HotkeyOption(rawValue: ""))
    }

    func testAllCasesCount() {
        // Guard against a case being added without test coverage being considered.
        XCTAssertEqual(HotkeyOption.allCases.count, 8)
    }

    // MARK: - id

    func testIdMatchesRawValueForAllCases() {
        for option in HotkeyOption.allCases {
            XCTAssertEqual(option.id, option.rawValue)
        }
    }

    // MARK: - keyCode mapping

    func testKeyCodeMapping() {
        XCTAssertEqual(HotkeyOption.fn.keyCode, 63)
        XCTAssertEqual(HotkeyOption.rightCommand.keyCode, 54)
        XCTAssertEqual(HotkeyOption.leftCommand.keyCode, 55)
        XCTAssertEqual(HotkeyOption.rightControl.keyCode, 62)
        XCTAssertEqual(HotkeyOption.leftControl.keyCode, 59)
        XCTAssertEqual(HotkeyOption.rightOption.keyCode, 61)
        XCTAssertEqual(HotkeyOption.leftOption.keyCode, 58)
    }

    func testChordKeyCodeIsSentinel() {
        // 0xFFFF signals that chords are matched by KeyboardShortcuts, not key code.
        XCTAssertEqual(HotkeyOption.chord.keyCode, 0xFFFF)
    }

    func testModifierKeyCodesAreUnique() {
        // Each physical modifier must map to a distinct macOS key code, otherwise
        // flagsChanged monitoring would confuse two keys.
        let modifierOptions = HotkeyOption.allCases.filter { $0 != .chord }
        let codes = modifierOptions.map(\.keyCode)
        XCTAssertEqual(Set(codes).count, codes.count, "duplicate key codes: \(codes)")
    }

    // MARK: - modifierFlag mapping

    func testModifierFlagMapping() {
        XCTAssertEqual(HotkeyOption.fn.modifierFlag, .function)
        XCTAssertEqual(HotkeyOption.rightCommand.modifierFlag, .command)
        XCTAssertEqual(HotkeyOption.leftCommand.modifierFlag, .command)
        XCTAssertEqual(HotkeyOption.rightControl.modifierFlag, .control)
        XCTAssertEqual(HotkeyOption.leftControl.modifierFlag, .control)
        XCTAssertEqual(HotkeyOption.rightOption.modifierFlag, .option)
        XCTAssertEqual(HotkeyOption.leftOption.modifierFlag, .option)
    }

    func testChordModifierFlagIsEmpty() {
        XCTAssertEqual(HotkeyOption.chord.modifierFlag, [])
    }

    // MARK: - displayName

    func testDisplayNameForAllCasesIsNonEmpty() {
        for option in HotkeyOption.allCases {
            XCTAssertFalse(option.displayName.isEmpty, "empty display name for \(option)")
        }
    }

    func testDisplayNameSpecificValues() {
        XCTAssertEqual(HotkeyOption.fn.displayName, "Fn")
        XCTAssertEqual(HotkeyOption.rightCommand.displayName, "Right ⌘")
        XCTAssertEqual(HotkeyOption.leftCommand.displayName, "Left ⌘")
        XCTAssertEqual(HotkeyOption.rightControl.displayName, "Right ⌃")
        XCTAssertEqual(HotkeyOption.leftControl.displayName, "Left ⌃")
        XCTAssertEqual(HotkeyOption.rightOption.displayName, "Right ⌥")
        XCTAssertEqual(HotkeyOption.leftOption.displayName, "Left ⌥")
        XCTAssertEqual(HotkeyOption.chord.displayName, "Custom Chord")
    }

    func testDisplayNamesAreUnique() {
        let names = HotkeyOption.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count, "duplicate display names: \(names)")
    }

    // MARK: - default

    func testDefaultIsFn() {
        XCTAssertEqual(HotkeyOption.default, .fn)
    }

    // MARK: - Codable round-trip

    func testCodableRoundTripForAllCases() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for option in HotkeyOption.allCases {
            let data = try encoder.encode(option)
            let decoded = try decoder.decode(HotkeyOption.self, from: data)
            XCTAssertEqual(decoded, option)
        }
    }

    // MARK: - binding(forKey:)

    func testBindingGetReturnsStoredOption() {
        let key = "HotkeyOptionTests.testBindingGetReturnsStoredOption"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        UserDefaults.standard.set(HotkeyOption.leftControl.rawValue, forKey: key)
        let binding = HotkeyOption.binding(forKey: key)
        XCTAssertEqual(binding.wrappedValue, .leftControl)
    }

    func testBindingGetReturnsDefaultWhenUnset() {
        let key = "HotkeyOptionTests.testBindingGetReturnsDefaultWhenUnset"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let binding = HotkeyOption.binding(forKey: key, default: .rightOption)
        XCTAssertEqual(binding.wrappedValue, .rightOption)
    }

    func testBindingGetReturnsDefaultWhenStoredValueIsInvalid() {
        let key = "HotkeyOptionTests.testBindingGetReturnsDefaultWhenStoredValueIsInvalid"
        defer { UserDefaults.standard.removeObject(forKey: key) }

        UserDefaults.standard.set("garbage", forKey: key)
        let binding = HotkeyOption.binding(forKey: key, default: .leftCommand)
        XCTAssertEqual(binding.wrappedValue, .leftCommand)
    }

    func testBindingSetPersistsRawValue() {
        let key = "HotkeyOptionTests.testBindingSetPersistsRawValue"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let binding = HotkeyOption.binding(forKey: key)
        binding.wrappedValue = .rightControl
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), HotkeyOption.rightControl.rawValue)
    }
}
