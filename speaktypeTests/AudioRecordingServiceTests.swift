import AVFoundation
import XCTest

@testable import speaktype

@MainActor
final class AudioRecordingServiceTests: XCTestCase {

    var service: AudioRecordingService!

    override func setUpWithError() throws {
        service = AudioRecordingService()
    }

    override func tearDownWithError() throws {
        service = nil
    }

    func testInitialization() {
        XCTAssertNotNil(service)
        XCTAssertFalse(service.isRecording)
        XCTAssertEqual(service.audioLevel, 0.0)
    }

    func testStopRecordingWhenNotRecording() async {
        let url = await service.stopRecording()
        XCTAssertNil(url, "Should return nil url when not recording")
    }

    // Note: Testing startRecording requires AVFoundation mocking or integration tests
    // due to hardware dependencies.

    // MARK: - selectedDeviceId persistence

    func testSelectedDeviceIdPersistsToUserDefaults() {
        let key = AudioRecordingService.selectedDeviceDefaultsKey
        let originalValue = UserDefaults.standard.string(forKey: key)
        let originalSelection = service.selectedDeviceId
        defer {
            // Restore the in-memory selection first (its didSet re-persists),
            // then put the defaults key back exactly as we found it.
            service.selectedDeviceId = originalSelection
            if let originalValue {
                UserDefaults.standard.set(originalValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        service.selectedDeviceId = "test-device-id"

        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "test-device-id")
    }
}

// MARK: - Device selection policy (pure)

@MainActor
final class AudioRecordingDeviceSelectionTests: XCTestCase {

    func testResolveSelectionKeepsPersistedDeviceWhenStillPresent() {
        let devices = [
            AudioDevice(id: "built-in", name: "MacBook Pro Microphone"),
            AudioDevice(id: "usb", name: "USB Microphone"),
        ]
        XCTAssertEqual(
            AudioRecordingService.resolveSelection(devices: devices, persistedId: "usb"),
            "usb"
        )
    }

    func testResolveSelectionFallsBackToFirstWhenPersistedDeviceGone() {
        let devices = [
            AudioDevice(id: "built-in", name: "MacBook Pro Microphone"),
            AudioDevice(id: "usb", name: "USB Microphone"),
        ]
        XCTAssertEqual(
            AudioRecordingService.resolveSelection(devices: devices, persistedId: "unplugged"),
            "built-in"
        )
    }

    func testResolveSelectionPicksFirstWhenNothingPersisted() {
        let devices = [
            AudioDevice(id: "built-in", name: "MacBook Pro Microphone"),
            AudioDevice(id: "usb", name: "USB Microphone"),
        ]
        XCTAssertEqual(
            AudioRecordingService.resolveSelection(devices: devices, persistedId: nil),
            "built-in"
        )
    }

    func testResolveSelectionSkipsTeamsVirtualDeviceAsFallback() {
        let devices = [
            AudioDevice(id: "teams", name: "Microsoft Teams Audio Device"),
            AudioDevice(id: "usb", name: "USB Microphone"),
        ]
        XCTAssertEqual(
            AudioRecordingService.resolveSelection(devices: devices, persistedId: nil),
            "usb"
        )
    }

    func testResolveSelectionDoesNotKeepPersistedTeamsDevice() {
        let devices = [
            AudioDevice(id: "teams", name: "Microsoft Teams Audio Device"),
            AudioDevice(id: "usb", name: "USB Microphone"),
        ]
        XCTAssertEqual(
            AudioRecordingService.resolveSelection(devices: devices, persistedId: "teams"),
            "usb"
        )
    }

    func testResolveSelectionReturnsNilForEmptyDeviceList() {
        XCTAssertNil(AudioRecordingService.resolveSelection(devices: [], persistedId: "usb"))
    }

    func testResolveSelectionReturnsNilWhenOnlyTeamsDevicesRemain() {
        let devices = [AudioDevice(id: "teams", name: "Microsoft Teams Audio Device")]
        XCTAssertNil(AudioRecordingService.resolveSelection(devices: devices, persistedId: nil))
    }

    func testIsSelectableDeviceFilterIsCaseInsensitive() {
        XCTAssertFalse(AudioRecordingService.isSelectableDevice(named: "microsoft teams audio"))
        XCTAssertTrue(AudioRecordingService.isSelectableDevice(named: "MacBook Pro Microphone"))
    }
}

// MARK: - Chunk rotation decision (pure)

@MainActor
final class AudioRecordingChunkRotationTests: XCTestCase {

    private let chunkStart = Date(timeIntervalSinceReferenceDate: 1000)

    func testShouldNotRotateBeforeChunkDuration() {
        XCTAssertFalse(
            AudioRecordingService.shouldRotateChunk(
                chunkStartTime: chunkStart,
                now: chunkStart.addingTimeInterval(3.999),
                isRotatingChunk: false
            )
        )
    }

    func testShouldRotateAtExactlyChunkDuration() {
        // The guard is `>=`, so the 4.0s boundary itself rotates.
        XCTAssertTrue(
            AudioRecordingService.shouldRotateChunk(
                chunkStartTime: chunkStart,
                now: chunkStart.addingTimeInterval(AudioRecordingService.chunkDuration),
                isRotatingChunk: false
            )
        )
    }

    func testShouldNotRotateWhenNoChunkSessionHasStarted() {
        // nil start = the chunk writer hasn't begun a session yet; appendToChunk
        // starts a new writer instead of rotating.
        XCTAssertFalse(
            AudioRecordingService.shouldRotateChunk(
                chunkStartTime: nil,
                now: chunkStart.addingTimeInterval(10),
                isRotatingChunk: false
            )
        )
    }

    func testShouldNotRotateWhileRotationIsInFlight() {
        XCTAssertFalse(
            AudioRecordingService.shouldRotateChunk(
                chunkStartTime: chunkStart,
                now: chunkStart.addingTimeInterval(10),
                isRotatingChunk: true
            )
        )
    }
}

// MARK: - Audio metrics DSP (pure)

@MainActor
final class AudioRecordingAudioMetricsTests: XCTestCase {

    private let sampleRate = 16000.0

    /// Builds a signal whose stride-4 subsampled values alternate sign every step,
    /// which is the maximum zero-crossing rate the DSP can observe.
    private func alternatingAtStride(amplitude: Float, count: Int) -> [Float] {
        (0..<count).map { ($0 / 4) % 2 == 0 ? amplitude : -amplitude }
    }

    func testSilenceIsGatedToZeroLevelAndFrequency() throws {
        let metrics = try XCTUnwrap(
            AudioRecordingService.audioMetrics(
                samples: .float32([Float](repeating: 0, count: 64)),
                sampleRate: sampleRate
            )
        )
        XCTAssertEqual(metrics.level, 0)
        XCTAssertEqual(metrics.frequency, 0)
    }

    func testFullScaleDCSignalReachesLevelOne() throws {
        let metrics = try XCTUnwrap(
            AudioRecordingService.audioMetrics(
                samples: .float32([Float](repeating: 1.0, count: 64)),
                sampleRate: sampleRate
            )
        )
        XCTAssertEqual(metrics.level, 1.0, accuracy: 0.0001)
        XCTAssertEqual(metrics.frequency, 0)  // DC never crosses zero
    }

    func testFullScaleSineLevelMatchesMinusThreeDB() throws {
        // RMS of a full-scale sine is 1/sqrt(2) = -3.01 dB -> (50 - 3.01) / 50 = 0.94.
        let samples = (0..<1024).map { Float(sin(2.0 * Double.pi * Double($0) / 64.0)) }
        let metrics = try XCTUnwrap(
            AudioRecordingService.audioMetrics(samples: .float32(samples), sampleRate: sampleRate)
        )
        XCTAssertEqual(metrics.level, 0.9398, accuracy: 0.005)
    }

    func testMinus25dBSignalMapsToMidLevel() throws {
        // DC amplitude 10^(-25/20): RMS = amplitude -> -25 dB -> (-25 + 50) / 50 = 0.5.
        let amplitude = Float(pow(10.0, -25.0 / 20.0))
        let metrics = try XCTUnwrap(
            AudioRecordingService.audioMetrics(
                samples: .float32([Float](repeating: amplitude, count: 64)),
                sampleRate: sampleRate
            )
        )
        XCTAssertEqual(metrics.level, 0.5, accuracy: 0.001)
    }

    func testInt16PathMatchesEquivalentFloat32Input() throws {
        // 16384 / 32768 == 0.5 exactly, so both paths see identical normalized samples.
        let int16Samples = (0..<64).map { ($0 / 4) % 2 == 0 ? Int16(16384) : Int16(-16384) }
        let floatSamples = alternatingAtStride(amplitude: 0.5, count: 64)

        let int16Metrics = try XCTUnwrap(
            AudioRecordingService.audioMetrics(samples: .int16(int16Samples), sampleRate: sampleRate)
        )
        let floatMetrics = try XCTUnwrap(
            AudioRecordingService.audioMetrics(samples: .float32(floatSamples), sampleRate: sampleRate)
        )
        XCTAssertEqual(int16Metrics.level, floatMetrics.level)
        XCTAssertEqual(int16Metrics.frequency, floatMetrics.frequency)
    }

    func testInt32PathMatchesEquivalentFloat32Input() throws {
        // 1073741824 / 2147483648 == 0.5 exactly.
        let int32Samples = (0..<64).map {
            ($0 / 4) % 2 == 0 ? Int32(1_073_741_824) : Int32(-1_073_741_824)
        }
        let floatSamples = alternatingAtStride(amplitude: 0.5, count: 64)

        let int32Metrics = try XCTUnwrap(
            AudioRecordingService.audioMetrics(samples: .int32(int32Samples), sampleRate: sampleRate)
        )
        let floatMetrics = try XCTUnwrap(
            AudioRecordingService.audioMetrics(samples: .float32(floatSamples), sampleRate: sampleRate)
        )
        XCTAssertEqual(int32Metrics.level, floatMetrics.level)
        XCTAssertEqual(int32Metrics.frequency, floatMetrics.frequency)
    }

    func testDCSignalHasZeroFrequency() throws {
        let metrics = try XCTUnwrap(
            AudioRecordingService.audioMetrics(
                samples: .float32([Float](repeating: 0.5, count: 64)),
                sampleRate: sampleRate
            )
        )
        XCTAssertEqual(metrics.frequency, 0)
    }

    func testAlternatingSignalClampsFrequencyToOne() throws {
        // Sign flip at every subsampled step -> ZCR near 1.0, x5 gain clamps to 1.0.
        let metrics = try XCTUnwrap(
            AudioRecordingService.audioMetrics(
                samples: .float32(alternatingAtStride(amplitude: 1.0, count: 64)),
                sampleRate: sampleRate
            )
        )
        XCTAssertEqual(metrics.frequency, 1.0)
        XCTAssertEqual(metrics.level, 1.0, accuracy: 0.0001)
    }

    func testSignalJustBelowGateZeroesLevelAndFrequency() throws {
        // 0.0032 RMS = -49.9 dB -> level 0.002, below the 0.01 gate. The gate must
        // also zero the frequency even though the signal crosses zero constantly.
        let metrics = try XCTUnwrap(
            AudioRecordingService.audioMetrics(
                samples: .float32(alternatingAtStride(amplitude: 0.0032, count: 64)),
                sampleRate: sampleRate
            )
        )
        XCTAssertEqual(metrics.level, 0)
        XCTAssertEqual(metrics.frequency, 0)
    }

    func testSignalJustAboveGateKeepsLevelAndFrequency() throws {
        // 0.0036 RMS = -48.9 dB -> level 0.023, above the gate: both metrics survive.
        let metrics = try XCTUnwrap(
            AudioRecordingService.audioMetrics(
                samples: .float32(alternatingAtStride(amplitude: 0.0036, count: 64)),
                sampleRate: sampleRate
            )
        )
        XCTAssertGreaterThan(metrics.level, 0.01)
        XCTAssertEqual(metrics.frequency, 1.0)
    }

    func testFewerSamplesThanOneStrideStepReturnsNil() {
        XCTAssertNil(
            AudioRecordingService.audioMetrics(
                samples: .float32([0.5, 0.5, 0.5]),
                sampleRate: sampleRate
            )
        )
        XCTAssertNil(
            AudioRecordingService.audioMetrics(samples: .float32([]), sampleRate: sampleRate)
        )
    }

    func testUnsupportedFormatYieldsZeroMetrics() throws {
        // Unknown formats (e.g. 24-bit int) read no samples: the original code still
        // published (0, 0) when at least one stride step of frames was present.
        let metrics = try XCTUnwrap(
            AudioRecordingService.audioMetrics(
                samples: .unsupported(frameCount: 64),
                sampleRate: sampleRate
            )
        )
        XCTAssertEqual(metrics.level, 0)
        XCTAssertEqual(metrics.frequency, 0)

        XCTAssertNil(
            AudioRecordingService.audioMetrics(
                samples: .unsupported(frameCount: 3),
                sampleRate: sampleRate
            )
        )
    }
}

// MARK: - Finished-file validation

@MainActor
final class AudioRecordingFileValidationTests: XCTestCase {

    private var tempURL: URL!

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioRecordingServiceTests-\(UUID().uuidString).wav")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempURL)
        tempURL = nil
    }

    /// Writes a real (silent) 16 kHz mono 16-bit WAV using the same settings as the
    /// recording pipeline, scoped so AVAudioFile closes before validation reads it.
    private func writeValidWAV(to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1600)
        )
        buffer.frameLength = 1600
        try file.write(from: buffer)
    }

    func testMissingFileReturnsNil() {
        XCTAssertNil(
            AudioRecordingService.validatedAudioFileURL(at: tempURL, writer: nil, label: "Test")
        )
    }

    func testZeroByteFileReturnsNil() {
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)
        XCTAssertNil(
            AudioRecordingService.validatedAudioFileURL(at: tempURL, writer: nil, label: "Test")
        )
    }

    func testValidWAVFileReturnsItsURL() throws {
        try writeValidWAV(to: tempURL)
        XCTAssertEqual(
            AudioRecordingService.validatedAudioFileURL(at: tempURL, writer: nil, label: "Test"),
            tempURL
        )
    }
}
