import SQLite3
import XCTest
@testable import speaktype

@MainActor
final class HistoryRecoveryTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL!
    private var journalURL: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var service: HistoryService!

    override func setUp() async throws {
        try await super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        databaseURL = directory.appendingPathComponent("history.sqlite")
        journalURL = databaseURL.appendingPathExtension("pending-mutations.json")
        suiteName = "speaktype.history.recovery.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        service = makeService()
        await service.waitUntilReady()
        XCTAssertNil(service.errorMessage)
    }

    override func tearDown() async throws {
        try? await service?.flushForTermination()
        service = nil
        if let suiteName { defaults?.removePersistentDomain(forName: suiteName) }
        defaults = nil
        if let directory {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let blockedDirectory = directory.appendingPathComponent("read-only", isDirectory: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blockedDirectory.path)
            let audioDirectory = directory.appendingPathComponent("protected-audio", isDirectory: true)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: audioDirectory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        try await super.tearDown()
    }

    private func makeService(
        recoveryJournalURL: URL? = nil,
        recoveryFaults: HistoryRecoveryFaults = .init()
    ) -> HistoryService {
        HistoryService(
            databaseURL: databaseURL,
            recoveryJournalURL: recoveryJournalURL ?? journalURL,
            defaults: defaults,
            recoveryFaults: recoveryFaults)
    }

    // A failed write used to fall out of the in-memory task chain. A later add
    // could then commit first, permanently reversing the user's operation order.
    func testFailedInsertQueuesLaterAddBehindOriginalMutation() async throws {
        try executeSQL("""
            CREATE TRIGGER reject_history_insert BEFORE INSERT ON history
            BEGIN SELECT RAISE(ABORT, 'forced insert failure'); END
            """)

        service.addItem(transcript: "first pending item", duration: 1)
        await service.flush()
        service.addItem(transcript: "second pending item", duration: 2)
        await service.flush()

        XCTAssertEqual(service.pendingMutationCount, 2)
        XCTAssertNotNil(service.recoveryErrorMessage)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM history"), 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM stats"), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))
    }

    // Reloading the visible snapshot used to clear the only indication that a
    // save had failed, even though nothing retried or recovered that save.
    func testRetryLoadingRetainsFailedMutationAndRecoveryError() async throws {
        try installInsertFailureTrigger()
        service.addItem(transcript: "must remain pending", duration: 1)
        await service.flush()
        let originalRecoveryError = try XCTUnwrap(service.recoveryErrorMessage)

        service.retryLoading()
        await service.flush()

        XCTAssertEqual(service.pendingMutationCount, 1)
        XCTAssertEqual(service.recoveryErrorMessage, originalRecoveryError)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM history"), 0)
    }

    func testRetryPendingWritesCommitsEachQueuedAddExactlyOnce() async throws {
        try installInsertFailureTrigger()
        service.addItem(transcript: "first queued", duration: 1)
        service.addItem(transcript: "second queued", duration: 2)
        await service.flush()
        XCTAssertEqual(service.pendingMutationCount, 2)

        try executeSQL("DROP TRIGGER reject_history_insert")
        service.retryPendingWrites()
        try await service.flushForTermination()
        service.retryPendingWrites()
        try await service.flushForTermination()

        XCTAssertEqual(service.pendingMutationCount, 0)
        XCTAssertNil(service.recoveryErrorMessage)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM history"), 2)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM stats"), 2)
        XCTAssertEqual(try scalar("SELECT COUNT(DISTINCT id) FROM stats"), 2)
        XCTAssertEqual(Set(service.items.map(\.transcript)), ["first queued", "second queued"])
    }

    func testRestartAutomaticallyReplaysDurablePendingMutation() async throws {
        try installInsertFailureTrigger()
        let audioURL = directory.appendingPathComponent("recovered.wav")
        service.addItem(
            transcript: "survives restart", duration: 4, audioFileURL: audioURL,
            modelUsed: "test-model", transcriptionTime: 0.75, detectedLanguage: "fr")
        await service.flush()
        XCTAssertEqual(service.pendingMutationCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))

        service = nil
        try executeSQL("DROP TRIGGER reject_history_insert")
        service = makeService()
        await service.waitUntilReady()
        try await service.flushForTermination()

        let recovered = try XCTUnwrap(service.items.first)
        XCTAssertEqual(recovered.transcript, "survives restart")
        XCTAssertEqual(recovered.duration, 4)
        XCTAssertEqual(recovered.audioFileURL, audioURL)
        XCTAssertEqual(recovered.modelUsed, "test-model")
        XCTAssertEqual(recovered.transcriptionTime, 0.75)
        XCTAssertEqual(recovered.detectedLanguage, "fr")
        XCTAssertEqual(service.pendingMutationCount, 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM stats"), 1)
    }

    // Production and beta builds can touch the same history directory. Two live
    // services that loaded an empty journal must not overwrite each other's later
    // pending writes with stale in-memory queues.
    func testTwoServicesSharingJournalPreserveBothPendingWritesForRestart() async throws {
        var firstService: HistoryService? = service
        var secondService: HistoryService? = makeService()
        await secondService?.waitUntilReady()
        try installInsertFailureTrigger()

        firstService?.addItem(transcript: "pending from first process", duration: 1)
        await firstService?.flush()
        secondService?.addItem(transcript: "pending from second process", duration: 2)
        await secondService?.flush()
        XCTAssertNotNil(firstService?.recoveryErrorMessage)
        XCTAssertNotNil(secondService?.recoveryErrorMessage)

        // Let the excluded writer acquire the lease and merge the first
        // process's on-disk mutation ahead of its own RAM-only mutation.
        service = nil
        firstService = nil
        secondService?.retryPendingWrites()
        await secondService?.flush()
        XCTAssertEqual(secondService?.pendingMutationCount, 2)
        secondService = nil
        try executeSQL("DROP TRIGGER reject_history_insert")
        service = makeService()
        await service.waitUntilReady()
        try await service.flushForTermination()

        XCTAssertEqual(
            Set(service.items.map(\.transcript)),
            ["pending from first process", "pending from second process"])
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM history"), 2)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM stats"), 2)
    }

    // A service excluded by another process initializes with its own stale stats
    // cache. Acquiring the journal lease must refresh that cache before it applies
    // RAM-only work, so the facade immediately includes both processes' commits.
    func testLeaseHandoffRefreshesHistoryAndStatisticsWithoutRestart() async throws {
        var firstService: HistoryService? = service
        let secondService = makeService()
        await secondService.waitUntilReady()

        firstService?.addItem(transcript: "alpha one two", duration: 2)
        await firstService?.flush()
        secondService.addItem(transcript: "beta three four five", duration: 4)
        await secondService.flush()
        XCTAssertEqual(secondService.pendingMutationCount, 1)

        service = nil
        firstService = nil
        secondService.retryPendingWrites()
        try await secondService.flushForTermination()

        XCTAssertEqual(secondService.totalItemCount, 2)
        XCTAssertEqual(
            Set(secondService.items.map(\.transcript)),
            ["alpha one two", "beta three four five"])
        XCTAssertEqual(secondService.transcriptionCount(), 2)
        XCTAssertEqual(secondService.totalWordCount(), 7)
        XCTAssertEqual(secondService.totalDuration(), 6)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM history"), 2)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM stats"), 2)
        service = secondService
    }

    // If cache refresh fails after lease acquisition, the service has read the
    // disk journal but has not merged it yet. New RAM work must remain blocked
    // from replacing that older journal until cache refresh can succeed.
    func testLeaseHandoffStatsFailurePreservesDiskJournalBeforeLaterRAMWork() async throws {
        var firstService: HistoryService? = service
        let recorder = AppliedTranscriptRecorder()
        let secondService = makeService(recoveryFaults: HistoryRecoveryFaults(
            afterApplyingMutation: { mutation in await recorder.record(mutation) }))
        await secondService.waitUntilReady()
        try installInsertFailureTrigger()
        firstService?.addItem(transcript: "first disk mutation", duration: 1)
        await firstService?.flush()
        let originalJournal = try Data(contentsOf: journalURL)
        try executeSQL("""
            INSERT INTO stats (id,date,words,duration,reference_date)
            VALUES ('malformed-id',0,99,1,NULL)
            """)

        service = nil
        firstService = nil
        secondService.retryPendingWrites()
        await secondService.flush()
        XCTAssertNotNil(secondService.recoveryErrorMessage)

        secondService.addItem(transcript: "second ram mutation", duration: 2)
        await secondService.flush()

        XCTAssertEqual(secondService.pendingMutationCount, 1)
        XCTAssertEqual(try Data(contentsOf: journalURL), originalJournal)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM history"), 0)
        let applicationsBeforeRepair = await recorder.transcripts()
        XCTAssertEqual(applicationsBeforeRepair, [])

        try executeSQL("DELETE FROM stats WHERE id = 'malformed-id'")
        try executeSQL("DROP TRIGGER reject_history_insert")
        secondService.retryPendingWrites()
        try await secondService.flushForTermination()

        let applicationsAfterRepair = await recorder.transcripts()
        XCTAssertEqual(applicationsAfterRepair, ["first disk mutation", "second ram mutation"])
        XCTAssertEqual(
            Set(secondService.items.map(\.transcript)),
            ["first disk mutation", "second ram mutation"])
        XCTAssertEqual(secondService.pendingMutationCount, 0)
        XCTAssertNil(secondService.recoveryErrorMessage)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM history"), 2)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM stats"), 2)
        service = secondService
    }

    // This reproduces a process interruption after SQLite commits but before the
    // mutation can be removed from the journal. Replay must consult the applied-op
    // ledger and clean the journal without inserting a second statistics row.
    func testReplayAfterCommitBeforeJournalCleanupIsIdempotent() async throws {
        await service.flush()
        service = nil
        let interruption = FailOnce()
        service = makeService(recoveryFaults: HistoryRecoveryFaults(
            afterApplyingMutation: { _ in try await interruption.throwIfNeeded() }))
        await service.waitUntilReady()

        service.addItem(transcript: "committed once", duration: 3)
        await service.flush()
        XCTAssertEqual(service.pendingMutationCount, 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM history"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM stats"), 1)

        service.retryPendingWrites()
        try await service.flushForTermination()

        XCTAssertEqual(service.pendingMutationCount, 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM history"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM stats"), 1)
        XCTAssertEqual(service.transcriptionCount(), 1)
        XCTAssertEqual(service.items.map(\.transcript), ["committed once"])
    }

    // A retry after the original audio has already been removed must not unlink
    // an unrelated file that was subsequently created at the same path.
    func testReplayedDeleteDoesNotRemoveReplacementAudioAtSamePath() async throws {
        let audioURL = directory.appendingPathComponent("reused.wav")
        let originalAudio = Data("original audio".utf8)
        let replacementAudio = Data("replacement audio".utf8)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try originalAudio.write(to: audioURL)
        service.addItem(transcript: "delete with audio", duration: 1, audioFileURL: audioURL)
        await service.flush()
        let itemID = try XCTUnwrap(service.items.first?.id)

        service = nil
        let interruption = FailOnce()
        service = makeService(recoveryFaults: HistoryRecoveryFaults(
            afterApplyingMutation: { _ in try await interruption.throwIfNeeded() }))
        await service.waitUntilReady()
        service.deleteItem(id: itemID)
        await service.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertEqual(service.pendingMutationCount, 1)

        try replacementAudio.write(to: audioURL)
        service.retryPendingWrites()
        try await service.flushForTermination()

        XCTAssertEqual(try Data(contentsOf: audioURL), replacementAudio)
        XCTAssertTrue(service.items.isEmpty)
        XCTAssertEqual(service.pendingMutationCount, 0)
        XCTAssertEqual(service.transcriptionCount(), 1)
    }

    // SQLite deletion can commit before filesystem cleanup. The original audio
    // identity must remain recoverable so a retry can finish that same deletion.
    func testRetryPendingDeleteRemovesOriginalAudioAfterPermissionFailure() async throws {
        let audioDirectory = directory.appendingPathComponent("protected-audio", isDirectory: true)
        let audioURL = audioDirectory.appendingPathComponent("original.wav")
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        try Data("original audio".utf8).write(to: audioURL)
        service.addItem(transcript: "retry audio cleanup", duration: 1, audioFileURL: audioURL)
        await service.flush()
        let itemID = try XCTUnwrap(service.items.first?.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: audioDirectory.path)

        service.deleteItem(id: itemID)
        await service.flush()

        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(service.items.isEmpty)
        XCTAssertEqual(service.pendingMutationCount, 1)
        XCTAssertNotNil(service.recoveryErrorMessage)

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: audioDirectory.path)
        service.retryPendingWrites()
        try await service.flushForTermination()

        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertEqual(service.pendingMutationCount, 0)
        XCTAssertNil(service.recoveryErrorMessage)
        XCTAssertEqual(service.transcriptionCount(), 1)
    }

    // The mutation is already durable when rendering the follow-up snapshot
    // fails. It must leave a presentation error, not a pending recovery entry.
    func testSuccessfulMutationFollowedBySnapshotFailureDoesNotRemainPending() async throws {
        try executeSQL("""
            CREATE TRIGGER corrupt_inserted_payload AFTER INSERT ON history
            BEGIN UPDATE history SET payload = X'00' WHERE id = NEW.id; END
            """)

        service.addItem(transcript: "durably committed", duration: 5)
        await service.flush()

        XCTAssertEqual(service.pendingMutationCount, 0)
        XCTAssertNil(service.recoveryErrorMessage)
        XCTAssertNotNil(service.errorMessage)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM history"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM stats"), 1)
        try await service.flushForTermination()
    }

    func testQueuedUpdateDeleteAndClearReplayInFIFOOrderWithoutDuplicateStats() async throws {
        service.addItem(transcript: "first original", duration: 1)
        service.addItem(transcript: "second original", duration: 2)
        await service.flush()
        let firstID = try XCTUnwrap(service.items.first { $0.transcript == "first original" }?.id)
        let secondID = try XCTUnwrap(service.items.first { $0.transcript == "second original" }?.id)
        try executeSQL("""
            CREATE TRIGGER reject_stats_update BEFORE UPDATE ON stats
            BEGIN SELECT RAISE(ABORT, 'forced update failure'); END
            """)

        service.updateTranscript(id: firstID, transcript: "first now has four")
        service.deleteItem(id: secondID, deleteAudioFile: false)
        service.addItem(transcript: "added before clear", duration: 3)
        service.clearAll()
        service.addItem(transcript: "final survivor", duration: 4)
        await service.flush()
        XCTAssertEqual(service.pendingMutationCount, 5)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM history"), 2)

        try executeSQL("DROP TRIGGER reject_stats_update")
        service.retryPendingWrites()
        try await service.flushForTermination()

        XCTAssertEqual(service.items.map(\.transcript), ["final survivor"])
        XCTAssertEqual(service.pendingMutationCount, 0)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM history"), 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM stats"), 4)
        XCTAssertEqual(try scalar("SELECT COUNT(DISTINCT id) FROM stats"), 4)
        XCTAssertEqual(service.transcriptionCount(), 4)
        XCTAssertEqual(service.totalWordCount(), 2 + 4 + 3 + 2)
    }

    func testCorruptJournalIsPreservedAndPreventsTerminationFlush() async throws {
        await service.flush()
        service = nil
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corruptData = Data("{not a mutation journal".utf8)
        try corruptData.write(to: journalURL)

        service = makeService()
        await service.waitUntilReady()

        XCTAssertNotNil(service.recoveryErrorMessage)
        XCTAssertEqual(try Data(contentsOf: journalURL), corruptData)
        service.addItem(transcript: "queued after damage", duration: 1)
        await service.flush()
        XCTAssertEqual(service.pendingMutationCount, 1)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM history"), 0)
        XCTAssertEqual(try Data(contentsOf: journalURL), corruptData)
        do {
            try await service.flushForTermination()
            XCTFail("Termination must wait for a readable, recoverable journal")
        } catch {
            XCTAssertEqual(try Data(contentsOf: journalURL), corruptData)
        }
    }

    func testUnwritableJournalPreventsSQLWriteAndTerminationFlush() async throws {
        await service.flush()
        service = nil
        let blockedDirectory = directory.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: blockedDirectory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: blockedDirectory.path)
        let blockedJournalURL = blockedDirectory.appendingPathComponent("pending.json")
        service = makeService(recoveryJournalURL: blockedJournalURL)
        await service.waitUntilReady()

        service.addItem(transcript: "cannot bypass journal", duration: 1)
        await service.flush()

        XCTAssertEqual(service.pendingMutationCount, 1)
        XCTAssertNotNil(service.recoveryErrorMessage)
        XCTAssertEqual(try scalar("SELECT COUNT(*) FROM history"), 0)
        do {
            try await service.flushForTermination()
            XCTFail("Termination must fail while a mutation cannot be journaled")
        } catch {
            XCTAssertEqual(try scalar("SELECT COUNT(*) FROM history"), 0)
        }
    }

    private func installInsertFailureTrigger() throws {
        try executeSQL("""
            CREATE TRIGGER reject_history_insert BEFORE INSERT ON history
            BEGIN SELECT RAISE(ABORT, 'forced insert failure'); END
            """)
    }

    private func executeSQL(_ sql: String) throws {
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            databaseURL.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard openStatus == SQLITE_OK, let database else {
            defer { if let database { sqlite3_close(database) } }
            throw SQLiteFixtureError.message("Could not open history fixture database")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard status == SQLITE_OK else {
            throw SQLiteFixtureError.message(
                errorMessage.map { String(cString: $0) } ?? "SQLite fixture failed")
        }
    }

    private func scalar(_ sql: String) throws -> Int {
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            databaseURL.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard openStatus == SQLITE_OK, let database else {
            defer { if let database { sqlite3_close(database) } }
            throw SQLiteFixtureError.message("Could not open history fixture database")
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteFixtureError.message(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteFixtureError.message(String(cString: sqlite3_errmsg(database)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }
}

private enum SQLiteFixtureError: Error {
    case message(String)
}

private actor FailOnce {
    private var shouldFail = true

    func throwIfNeeded() throws {
        guard shouldFail else { return }
        shouldFail = false
        throw SimulatedInterruption()
    }
}

private actor AppliedTranscriptRecorder {
    private var values: [String] = []

    func record(_ mutation: HistoryMutation) {
        guard case .add(let item) = mutation.operation else { return }
        values.append(item.transcript)
    }

    func transcripts() -> [String] { values }
}

private struct SimulatedInterruption: LocalizedError {
    var errorDescription: String? { "Simulated interruption after SQLite commit" }
}
