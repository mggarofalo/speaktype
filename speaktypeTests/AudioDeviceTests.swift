import XCTest
@testable import speaktype

// All logic in AudioDevice and its supporting types is pure value-type logic
// (string formatting, enum mapping, Codable). Nothing here touches CoreAudio,
// so there is nothing hardware-gated to skip in this file.
final class AudioDeviceTests: XCTestCase {

    // MARK: - Initialization defaults

    func testInitAppliesDocumentedDefaults() {
        let device = AudioDevice(id: "dev1", name: "Mic")
        XCTAssertNil(device.manufacturer)
        XCTAssertFalse(device.isDefault)
        XCTAssertFalse(device.isActive)
        XCTAssertEqual(device.channels, 1)
        XCTAssertEqual(device.sampleRate, 48000.0)
        XCTAssertEqual(device.deviceType, .builtin)
        XCTAssertTrue(device.isConnected)
    }

    // MARK: - fullName

    func testFullNameIncludesManufacturerWhenPresent() {
        let device = AudioDevice(id: "1", name: "Studio Mic", manufacturer: "Acme")
        XCTAssertEqual(device.fullName, "Acme - Studio Mic")
    }

    func testFullNameOmitsManufacturerWhenNil() {
        let device = AudioDevice(id: "1", name: "Studio Mic", manufacturer: nil)
        XCTAssertEqual(device.fullName, "Studio Mic")
    }

    func testFullNameOmitsManufacturerWhenEmpty() {
        // An empty manufacturer string must not produce a dangling " - " prefix.
        let device = AudioDevice(id: "1", name: "Studio Mic", manufacturer: "")
        XCTAssertEqual(device.fullName, "Studio Mic")
    }

    // MARK: - description

    func testDescriptionMono() {
        let device = AudioDevice(id: "1", name: "Mic", channels: 1, sampleRate: 48000.0)
        XCTAssertEqual(device.description, "Mono, 48kHz")
    }

    func testDescriptionMultiChannel() {
        let device = AudioDevice(id: "1", name: "Mic", channels: 2, sampleRate: 16000.0)
        XCTAssertEqual(device.description, "2 channels, 16kHz")
    }

    // MARK: - iconName delegation

    func testIconNameDelegatesToDeviceType() {
        let device = AudioDevice(id: "1", name: "Mic", deviceType: .bluetooth)
        XCTAssertEqual(device.iconName, AudioDeviceType.bluetooth.iconName)
    }

    // MARK: - Equatable

    func testEqualDevicesCompareEqual() {
        let a = AudioDevice(id: "1", name: "Mic")
        let b = AudioDevice(id: "1", name: "Mic")
        XCTAssertEqual(a, b)
    }

    func testDevicesWithDifferentActiveStateAreNotEqual() {
        let a = AudioDevice(id: "1", name: "Mic", isActive: false)
        let b = AudioDevice(id: "1", name: "Mic", isActive: true)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Codable round-trip

    func testCodableRoundTrip() throws {
        let original = AudioDevice(
            id: "dev-42",
            name: "External Mic",
            manufacturer: "Acme",
            isDefault: true,
            isActive: true,
            channels: 2,
            sampleRate: 44100.0,
            deviceType: .usb,
            isConnected: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AudioDevice.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - systemDefault factory

    func testSystemDefaultFactory() {
        let device = AudioDevice.systemDefault
        XCTAssertEqual(device.id, "system-default")
        XCTAssertTrue(device.isDefault)
        XCTAssertEqual(device.deviceType, .builtin)
    }
}

// MARK: - AudioDeviceType

final class AudioDeviceTypeTests: XCTestCase {

    private let allTypes: [AudioDeviceType] = [
        .builtin, .usb, .bluetooth, .aggregate, .virtual, .unknown,
    ]

    func testIconNameNonEmptyForAllTypes() {
        for type in allTypes {
            XCTAssertFalse(type.iconName.isEmpty, "empty icon for \(type)")
        }
    }

    func testIconNamesAreUnique() {
        let icons = allTypes.map(\.iconName)
        XCTAssertEqual(Set(icons).count, icons.count, "duplicate icons: \(icons)")
    }

    func testDisplayNameMatchesRawValue() {
        for type in allTypes {
            XCTAssertEqual(type.displayName, type.rawValue)
        }
    }

    func testCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for type in allTypes {
            let data = try encoder.encode(type)
            let decoded = try decoder.decode(AudioDeviceType.self, from: data)
            XCTAssertEqual(decoded, type)
        }
    }
}

// MARK: - AudioDevicePreferences

final class AudioDevicePreferencesTests: XCTestCase {

    func testDefaultPreferences() {
        let prefs = AudioDevicePreferences.default
        XCTAssertEqual(prefs.inputMode, .systemDefault)
        XCTAssertNil(prefs.selectedDeviceId)
        XCTAssertTrue(prefs.priorityOrder.isEmpty)
        XCTAssertFalse(prefs.autoSwitchToNewDevices)
    }

    func testCodableRoundTrip() throws {
        let original = AudioDevicePreferences(
            inputMode: .prioritized,
            selectedDeviceId: "dev-1",
            priorityOrder: ["dev-1", "dev-2"],
            autoSwitchToNewDevices: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AudioDevicePreferences.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}

// MARK: - InputMode

final class InputModeTests: XCTestCase {

    func testAllCasesHaveNonEmptyDescriptionAndIcon() {
        for mode in InputMode.allCases {
            XCTAssertFalse(mode.description.isEmpty, "empty description for \(mode)")
            XCTAssertFalse(mode.iconName.isEmpty, "empty icon for \(mode)")
        }
    }

    func testIdMatchesRawValue() {
        for mode in InputMode.allCases {
            XCTAssertEqual(mode.id, mode.rawValue)
        }
    }

    func testCodableRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for mode in InputMode.allCases {
            let data = try encoder.encode(mode)
            let decoded = try decoder.decode(InputMode.self, from: data)
            XCTAssertEqual(decoded, mode)
        }
    }
}
