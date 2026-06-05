import AVFoundation
import XCTest
@testable import speaktype

final class RecordingSessionTests: XCTestCase {

    // MARK: - duration

    func testDurationUsesEndTimeWhenSet() {
        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 1010)
        let session = RecordingSession(startTime: start, endTime: end)
        XCTAssertEqual(session.duration, 10, accuracy: 0.0001)
    }

    func testDurationUsesNowWhenStillRecording() {
        // With no endTime, duration is measured against "now" and should be non-negative.
        let start = Date(timeIntervalSinceNow: -5)
        let session = RecordingSession(startTime: start, endTime: nil)
        XCTAssertGreaterThanOrEqual(session.duration, 5)
        XCTAssertLessThan(session.duration, 60)
    }

    // MARK: - isRecording / isCompleted

    func testIsRecordingTrueOnlyInRecordingState() {
        XCTAssertTrue(RecordingSession(state: .recording).isRecording)
        XCTAssertFalse(RecordingSession(state: .paused).isRecording)
        XCTAssertFalse(RecordingSession(state: .completed).isRecording)
        XCTAssertFalse(RecordingSession(state: .cancelled).isRecording)
        XCTAssertFalse(RecordingSession(state: .failed).isRecording)
    }

    func testIsCompletedRequiresCompletedStateAndNoError() {
        XCTAssertTrue(RecordingSession(state: .completed, error: nil).isCompleted)
    }

    func testIsCompletedFalseWhenStateNotCompleted() {
        XCTAssertFalse(RecordingSession(state: .recording).isCompleted)
    }

    func testIsCompletedFalseWhenCompletedButHasError() {
        // A completed state paired with an error is contradictory and must not count as completed.
        let session = RecordingSession(state: .completed, error: .fileWriteError)
        XCTAssertFalse(session.isCompleted)
    }

    // MARK: - formattedDuration

    func testFormattedDurationPadsMinutesAndSeconds() {
        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 5)
        let session = RecordingSession(startTime: start, endTime: end)
        XCTAssertEqual(session.formattedDuration, "00:05")
    }

    func testFormattedDurationOverOneMinute() {
        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 125)
        let session = RecordingSession(startTime: start, endTime: end)
        XCTAssertEqual(session.formattedDuration, "02:05")
    }

    // MARK: - averageLevel / peakLevel

    func testAverageLevelEmptyIsZero() {
        let session = RecordingSession(audioLevels: [])
        XCTAssertEqual(session.averageLevel, 0.0)
    }

    func testAverageLevelComputesMean() {
        let session = RecordingSession(audioLevels: [0.2, 0.4, 0.6])
        XCTAssertEqual(session.averageLevel, 0.4, accuracy: 0.0001)
    }

    func testPeakLevelEmptyIsZero() {
        let session = RecordingSession(audioLevels: [])
        XCTAssertEqual(session.peakLevel, 0.0)
    }

    func testPeakLevelReturnsMaximum() {
        let session = RecordingSession(audioLevels: [0.1, 0.9, 0.3])
        XCTAssertEqual(session.peakLevel, 0.9, accuracy: 0.0001)
    }

    // MARK: - Factory methods

    func testNewFactoryStartsInRecordingState() {
        let session = RecordingSession.new()
        XCTAssertEqual(session.state, .recording)
        XCTAssertNil(session.endTime)
        XCTAssertNil(session.error)
        XCTAssertTrue(session.isRecording)
    }

    func testFailedFactoryCarriesErrorAndState() {
        let session = RecordingSession.failed(error: .permissionDenied)
        XCTAssertEqual(session.state, .failed)
        XCTAssertEqual(session.error, .permissionDenied)
        XCTAssertFalse(session.isCompleted)
    }

    // MARK: - Equatable

    func testEqualSessionsCompareEqual() {
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1000)
        let a = RecordingSession(id: id, startTime: start, audioLevels: [0.1])
        let b = RecordingSession(id: id, startTime: start, audioLevels: [0.1])
        XCTAssertEqual(a, b)
    }

    func testSessionsWithDifferentLevelsAreNotEqual() {
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1000)
        let a = RecordingSession(id: id, startTime: start, audioLevels: [0.1])
        let b = RecordingSession(id: id, startTime: start, audioLevels: [0.2])
        XCTAssertNotEqual(a, b)
    }
}

// MARK: - RecordingState

final class RecordingStateTests: XCTestCase {

    func testCodableRoundTripForAllStates() throws {
        let states: [RecordingState] = [.recording, .paused, .completed, .cancelled, .failed]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for state in states {
            let data = try encoder.encode(state)
            let decoded = try decoder.decode(RecordingState.self, from: data)
            XCTAssertEqual(decoded, state)
        }
    }
}

// MARK: - AudioFormat

final class AudioFormatTests: XCTestCase {

    func testDefaultIsWhisperOptimized() {
        let format = AudioFormat.default
        XCTAssertEqual(format.sampleRate, 16000.0)
        XCTAssertEqual(format.channels, 1)
        XCTAssertEqual(format.bitDepth, 16)
        XCTAssertEqual(format.formatID, kAudioFormatLinearPCM)
    }

    func testHighQualityFormatValues() {
        let format = AudioFormat.highQuality
        XCTAssertEqual(format.sampleRate, 48000.0)
        XCTAssertEqual(format.channels, 1)
        XCTAssertEqual(format.bitDepth, 24)
    }

    func testDescriptionMono() {
        XCTAssertEqual(AudioFormat.default.description, "16kHz, 1ch, 16-bit")
    }

    func testDescriptionHighQuality() {
        XCTAssertEqual(AudioFormat.highQuality.description, "48kHz, 1ch, 24-bit")
    }

    func testCodableRoundTrip() throws {
        let original = AudioFormat.highQuality
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AudioFormat.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testEquatable() {
        XCTAssertEqual(AudioFormat.default, AudioFormat.default)
        XCTAssertNotEqual(AudioFormat.default, AudioFormat.highQuality)
    }
}

// MARK: - RecordingError

final class RecordingErrorTests: XCTestCase {

    func testErrorDescriptionsAreNonEmpty() {
        let errors: [RecordingError] = [
            .permissionDenied,
            .audioEngineFailure,
            .fileWriteError,
            .maxDurationExceeded,
            .audioInputUnavailable,
            .unknown("detail"),
        ]
        for error in errors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "empty description for \(error)")
        }
    }

    func testUnknownErrorEmbedsMessage() {
        let error = RecordingError.unknown("disk full")
        XCTAssertEqual(error.errorDescription, "Recording error: disk full")
    }

    func testEquatableDistinguishesUnknownPayloads() {
        XCTAssertEqual(RecordingError.unknown("a"), RecordingError.unknown("a"))
        XCTAssertNotEqual(RecordingError.unknown("a"), RecordingError.unknown("b"))
        XCTAssertNotEqual(RecordingError.permissionDenied, RecordingError.fileWriteError)
    }
}
