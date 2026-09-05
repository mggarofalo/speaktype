import XCTest
@testable import speaktype

@MainActor
final class HistoryServiceTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var service: HistoryService!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        suiteName = "speaktype.history.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        service = makeService()
        await service.waitUntilReady()
    }

    override func tearDown() async throws {
        await service?.flush()
        service = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeService() -> HistoryService {
        HistoryService(databaseURL: directory.appendingPathComponent("history.sqlite"), defaults: defaults)
    }

    private func migrate(_ items: [HistoryItem], stats: [HistoryStatsEntry]? = nil) async throws {
        await service.flush()
        service = nil
        // Tests recreate only their own isolated database, never application data.
        try? FileManager.default.removeItem(at: directory)
        defaults.set(try JSONEncoder().encode(items), forKey: "history_items")
        if let stats { defaults.set(try JSONEncoder().encode(stats), forKey: "history_stats_entries") }
        service = makeService()
        await service.waitUntilReady()
        XCTAssertNil(service.errorMessage)
    }

    func testAddPersistenceAndMetadata() async throws {
        service.addItem(transcript: "Bonjour le monde", duration: 3,
            audioFileURL: directory.appendingPathComponent("voice.wav"), modelUsed: "test",
            transcriptionTime: 0.5, detectedLanguage: "fr")
        await service.flush()
        let original = try XCTUnwrap(service.items.first)
        let restarted = makeService()
        await restarted.waitUntilReady()
        let loaded = try XCTUnwrap(restarted.items.first)
        XCTAssertEqual(loaded.transcript, original.transcript)
        XCTAssertEqual(loaded.audioFileURL, original.audioFileURL)
        XCTAssertEqual(loaded.detectedLanguage, "fr")
        XCTAssertEqual(loaded.transcriptionTime, 0.5)
        XCTAssertEqual(loaded.id, original.id)
        XCTAssertEqual(restarted.totalWordCount(), 3)
        XCTAssertEqual(restarted.totalDuration(), 3)
        XCTAssertEqual(restarted.transcriptionCount(), 1)
        XCTAssertEqual(restarted.statsEntries.first?.date, original.date)
    }

    func testQueuedOperationsDuringInitialLoadStayOrdered() async throws {
        let now = Date()
        let legacy = HistoryItem(id: UUID(), date: now, transcript: "legacy", duration: 1)
        try await migrate([legacy])
        service = makeService()
        service.addItem(transcript: "before clear", duration: 2)
        service.clearAll()
        service.addItem(transcript: "after clear", duration: 3)
        await service.flush()
        XCTAssertEqual(service.items.map(\.transcript), ["after clear"])
        XCTAssertEqual(service.transcriptionCount(), 3)
        XCTAssertEqual(service.totalDuration(), 6)
        let restarted = makeService()
        await restarted.waitUntilReady()
        XCTAssertEqual(restarted.items.map(\.transcript), ["after clear"])
    }

    func testDeleteAndClearRetainStatisticsAndClearRetainsAudio() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let firstAudio = directory.appendingPathComponent("first.wav")
        let secondAudio = directory.appendingPathComponent("second.wav")
        try Data("audio".utf8).write(to: firstAudio)
        try Data("audio".utf8).write(to: secondAudio)
        service.addItem(transcript: "one two", duration: 2, audioFileURL: firstAudio)
        service.addItem(transcript: "three", duration: 3, audioFileURL: secondAudio)
        await service.flush()
        let firstID = try XCTUnwrap(service.items.first(where: { $0.audioFileURL == firstAudio })?.id)
        service.deleteItem(id: firstID)
        await service.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstAudio.path))
        service.clearAll()
        await service.flush()
        XCTAssertTrue(service.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secondAudio.path))
        XCTAssertEqual(service.totalWordCount(), 3)
        XCTAssertEqual(service.totalDuration(), 5)
        XCTAssertEqual(service.transcriptionCount(), 2)
        let restarted = makeService()
        await restarted.waitUntilReady()
        XCTAssertTrue(restarted.items.isEmpty)
        XCTAssertEqual(restarted.transcriptionCount(), 2)
    }

    func testUpdateOutsideRecentPagePreservesFieldsAndRefreshesSearch() async throws {
        let entries = (0..<80).map { index in
            HistoryItem(id: UUID(), date: Date(timeIntervalSince1970: Double(index)),
                transcript: "old transcript \(index)", duration: 2,
                audioFileURL: directory.appendingPathComponent("\(index).wav"),
                modelUsed: "original", transcriptionTime: 1, detectedLanguage: "fr")
        }
        try await migrate(entries)
        let original = entries[0]
        XCTAssertFalse(service.items.contains { $0.id == original.id })
        service.updateTranscript(id: original.id, transcript: "replacement unique", modelUsed: "new", transcriptionTime: 0.4)
        await service.flush()
        let page = try await service.query(search: "replacement")
        let updated = try XCTUnwrap(page.items.first)
        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.date, original.date)
        XCTAssertEqual(updated.duration, original.duration)
        XCTAssertEqual(updated.audioFileURL, original.audioFileURL)
        XCTAssertEqual(updated.detectedLanguage, "fr")
        XCTAssertEqual(updated.modelUsed, "new")
        XCTAssertEqual(updated.transcriptionTime, 0.4)
        XCTAssertEqual(service.totalWordCount(), 79 * 3 + 2)
        service.updateTranscript(id: original.id, transcript: "  ")
        service.updateTranscript(id: UUID(), transcript: "unknown")
        await service.flush()
        XCTAssertEqual(service.totalItemCount, 80)
        let remaining = try await service.query(search: "replacement")
        XCTAssertEqual(remaining.totalCount, 1)
    }

    func testMigrationKeepsDeletedStatsAndLegacyRecoveryCopyWithoutReimport() async throws {
        let item = HistoryItem(id: UUID(), date: Date(), transcript: "Untouched  spacing um", duration: 3,
            detectedLanguage: "de")
        // This value loses a bit if persisted as Unix seconds and converted back.
        let preciseDate = Date(timeIntervalSinceReferenceDate: 810_123_456.1234568)
        let stat = HistoryStatsEntry(id: UUID(), date: preciseDate, wordCount: 99, duration: 50)
        try await migrate([item], stats: [stat])
        XCTAssertEqual(service.items.first?.transcript, item.transcript)
        XCTAssertEqual(service.items.first?.detectedLanguage, "de")
        XCTAssertEqual(service.statsEntries, [stat])
        XCTAssertNotNil(defaults.data(forKey: "history_items"))
        service.clearAll()
        await service.flush()
        let restarted = makeService()
        await restarted.waitUntilReady()
        XCTAssertTrue(restarted.items.isEmpty)
        XCTAssertEqual(restarted.statsEntries, [stat])
    }

    // A legacy archive can contain a live transcript whose statistics row was
    // already absent. Editing it must not synthesize a cache-only statistic that
    // disappears on restart.
    func testUpdateMigratedItemWithoutStatsDoesNotCreatePhantomStatistic() async throws {
        let item = HistoryItem(
            id: UUID(), date: Date(), transcript: "original words", duration: 3)
        let retainedDeletedStat = HistoryStatsEntry(
            id: UUID(), date: Date(timeIntervalSince1970: 100), wordCount: 7, duration: 8)
        try await migrate([item], stats: [retainedDeletedStat])
        XCTAssertEqual(service.statsEntries, [retainedDeletedStat])

        service.updateTranscript(id: item.id, transcript: "replacement has four words")
        await service.flush()

        XCTAssertEqual(service.items.first?.transcript, "replacement has four words")
        XCTAssertEqual(service.statsEntries, [retainedDeletedStat])
        XCTAssertEqual(service.transcriptionCount(), 1)
        let restarted = makeService()
        await restarted.waitUntilReady()
        XCTAssertEqual(restarted.statsEntries, [retainedDeletedStat])
    }

    func testMalformedMigrationRollsBackAndCanRetry() async throws {
        await service.flush()
        service = nil
        try FileManager.default.removeItem(at: directory)
        defaults.set(Data("broken json".utf8), forKey: "history_items")
        service = makeService()
        await service.waitUntilReady()
        XCTAssertNotNil(service.errorMessage)
        XCTAssertTrue(service.items.isEmpty)
        let entry = HistoryItem(id: UUID(), date: Date(), transcript: "recovered", duration: 1)
        defaults.set(try JSONEncoder().encode([entry]), forKey: "history_items")
        service.retryLoading()
        await service.flush()
        XCTAssertNil(service.errorMessage)
        XCTAssertNil(service.recoveryErrorMessage)
        XCTAssertEqual(service.items.first?.id, entry.id)
        service.addItem(transcript: "saved after retry", duration: 1)
        await service.flush()
        XCTAssertEqual(service.pendingMutationCount, 0)
        XCTAssertEqual(service.totalItemCount, 2)
    }

    // Dismissing a banner must not hide the next independent failure with the same text.
    func testRepeatedStorageFailuresHaveDistinctOccurrences() async throws {
        await service.flush()
        service = nil
        try? FileManager.default.removeItem(at: directory)
        defaults.set(Data("not json".utf8), forKey: "history_items")
        service = makeService()
        await service.waitUntilReady()
        let firstMessage = try XCTUnwrap(service.errorMessage)
        let firstOccurrence = service.errorRevision
        service.retryLoading()
        await service.waitUntilReady()
        XCTAssertEqual(service.errorMessage, firstMessage)
        XCTAssertGreaterThan(service.errorRevision, firstOccurrence)
    }

    func testPaginationSearchAndKeysetAreStableWithEqualDates() async throws {
        let date = Date(timeIntervalSince1970: 1000)
        let entries = (0..<137).map { index in
            HistoryItem(id: UUID(), date: date, transcript: index == 70 ? "Café 100%_done" : "entry \(index)", duration: 1)
        }
        try await migrate(entries)
        XCTAssertEqual(service.items.count, 50)
        XCTAssertEqual(service.totalItemCount, 137)
        var ids: [UUID] = []
        for offset in stride(from: 0, to: 137, by: 50) {
            let page = try await service.query(limit: 50, offset: offset)
            XCTAssertEqual(page.totalCount, 137)
            ids += page.items.map(\.id)
        }
        XCTAssertEqual(Set(ids).count, 137)
        XCTAssertEqual(ids.map(\.uuidString), entries.map(\.id.uuidString).sorted(by: >))
        let first = try await service.query(limit: 50)
        let cursorItem = try XCTUnwrap(first.items.last)
        let next = try await service.query(limit: 50, after: HistoryCursor(date: cursorItem.date, id: cursorItem.id))
        XCTAssertEqual(next.items.map(\.id), Array(ids[50..<100]))
        let result = try await service.query(search: "CAFE 100%_")
        XCTAssertEqual(result.items.map(\.id), [entries[70].id])
        let literal = try await service.query(search: "%")
        XCTAssertEqual(literal.totalCount, 1)
        let noMatches = try await service.query(search: "missing")
        XCTAssertTrue(noMatches.items.isEmpty)
    }

    func testStatisticsDateQueries() async throws {
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        try await migrate([], stats: [
            HistoryStatsEntry(id: UUID(), date: today, wordCount: 4, duration: 5),
            HistoryStatsEntry(id: UUID(), date: yesterday, wordCount: 8, duration: 9)])
        XCTAssertEqual(service.wordCount(on: today), 4)
        XCTAssertEqual(service.wordCount(on: yesterday), 8)
        XCTAssertEqual(service.totalDuration(since: Calendar.current.startOfDay(for: today)), 5)
        XCTAssertEqual(service.transcriptionCount(since: Calendar.current.startOfDay(for: today)), 1)
        XCTAssertEqual(service.totalWordCount(), 12)
    }

    func testTenThousandEntryArchiveRetainsOnlyRecentPage() async throws {
        let entries = (0..<10_000).map { index in
            HistoryItem(id: UUID(), date: Date(timeIntervalSince1970: Double(index)),
                transcript: "Synthetic archive transcript number \(index)", duration: 1)
        }
        let start = Date()
        try await migrate(entries)
        let migrationSeconds = Date().timeIntervalSince(start)
        let queryStart = Date()
        let result = try await service.query(search: "number 9999", limit: 50)
        let querySeconds = Date().timeIntervalSince(queryStart)
        XCTAssertEqual(service.items.count, 50)
        XCTAssertEqual(service.totalItemCount, 10_000)
        XCTAssertEqual(result.items.map(\.id), [entries.last!.id])
        let attachment = XCTAttachment(string:
            "10000 entries: migration=\(migrationSeconds)s, search=\(querySeconds)s, "
                + "resident transcripts=\(service.items.count)")
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
