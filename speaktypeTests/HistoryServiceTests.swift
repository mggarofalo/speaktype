import XCTest
@testable import speaktype

final class HistoryServiceTests: XCTestCase {
    
    var service: HistoryService!
    
    override func setUp() {
        super.setUp()
        service = HistoryService.shared
        service.resetAllDataForTesting()
    }
    
    override func tearDown() {
        service.resetAllDataForTesting()
        super.tearDown()
    }
    
    func testAddItem() {
        XCTAssertTrue(service.items.isEmpty)
        
        let transcript = "Test Transcript"
        let duration: TimeInterval = 10.0
        
        service.addItem(transcript: transcript, duration: duration)
        
        XCTAssertEqual(service.items.count, 1)
        XCTAssertEqual(service.items.first?.transcript, transcript)
        XCTAssertEqual(service.items.first?.duration, duration)
    }
    
    func testPersistence() {
        let transcript = "Persistent Item"
        service.addItem(transcript: transcript, duration: 5.0)
        
        // Simulate app restart by re-initializing (or checking UserDefaults directly)
        // Since 'init' loads from UserDefaults, creating a new instance isn't easy with singleton,
        // but we can check if UserDefaults has the data.
        
        guard let data = UserDefaults.standard.data(forKey: "history_items"),
              let decoded = try? JSONDecoder().decode([HistoryItem].self, from: data) else {
            XCTFail("Failed to load from UserDefaults")
            return
        }
        
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.transcript, transcript)
    }
    
    func testDeleteItem() {
        service.addItem(transcript: "Item 1", duration: 1.0)
        service.addItem(transcript: "Item 2", duration: 2.0)
        
        XCTAssertEqual(service.items.count, 2)
        
        let itemToDelete = service.items.last! // "Item 1" (since newest is first)
        service.deleteItem(id: itemToDelete.id)
        
        XCTAssertEqual(service.items.count, 1)
        XCTAssertEqual(service.items.first?.transcript, "Item 2")
    }

    func testDeleteItemRemovesAudioFileWhenPresent() throws {
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        try Data("audio".utf8).write(to: audioURL)

        service.addItem(
            transcript: "Item with audio",
            duration: 1.0,
            audioFileURL: audioURL
        )

        let itemID = try XCTUnwrap(service.items.first?.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))

        service.deleteItem(id: itemID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(service.items.isEmpty)
    }

    func testClearAllPreservesStatsHistory() {
        service.addItem(transcript: "One short note", duration: 10.0)
        service.addItem(transcript: "Another slightly longer note", duration: 20.0)

        let countBeforeClear = service.transcriptionCount()
        let wordsBeforeClear = service.totalWordCount()
        let durationBeforeClear = service.totalDuration()

        service.clearAll()

        XCTAssertTrue(service.items.isEmpty)
        XCTAssertEqual(service.transcriptionCount(), countBeforeClear)
        XCTAssertEqual(service.totalWordCount(), wordsBeforeClear)
        XCTAssertEqual(service.totalDuration(), durationBeforeClear)
    }

    func testStatsPersistenceUsesSeparateStore() {
        service.addItem(transcript: "Persistent stats entry", duration: 5.0)

        guard let data = UserDefaults.standard.data(forKey: "history_stats_entries"),
              let decoded = try? JSONDecoder().decode([HistoryStatsEntry].self, from: data) else {
            XCTFail("Failed to load stats from UserDefaults")
            return
        }

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.wordCount, 3)
        XCTAssertEqual(decoded.first?.duration, 5.0)
    }

    // MARK: - Stats query helpers
    //
    // addItem always stamps entries with Date() (now), so date-sensitive tests
    // seed crafted HistoryStatsEntry arrays into UserDefaults and reload through
    // the real persistence path.

    private func seedStats(_ entries: [HistoryStatsEntry]) {
        let encoded = try! JSONEncoder().encode(entries)
        UserDefaults.standard.set(encoded, forKey: "history_stats_entries")
        service.reloadFromPersistenceForTesting()
    }

    func testWordCountOnDayFiltersByCalendarDay() {
        let calendar = Calendar.current
        let today = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        seedStats([
            HistoryStatsEntry(id: UUID(), date: today, wordCount: 5, duration: 1.0),
            HistoryStatsEntry(id: UUID(), date: today, wordCount: 3, duration: 1.0),
            HistoryStatsEntry(id: UUID(), date: yesterday, wordCount: 9, duration: 1.0),
        ])

        XCTAssertEqual(service.wordCount(on: today), 8)
        XCTAssertEqual(service.wordCount(on: yesterday), 9)
    }

    func testWordCountOnDayIsZeroWhenNoEntriesForDay() {
        let calendar = Calendar.current
        let today = Date()
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: today)!

        seedStats([
            HistoryStatsEntry(id: UUID(), date: today, wordCount: 4, duration: 1.0),
        ])

        XCTAssertEqual(service.wordCount(on: twoDaysAgo), 0)
    }

    func testStatsEntriesSinceFiltersByDate() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-3600) // 1h ago
        let recent = now.addingTimeInterval(-60)    // 1m ago — after cutoff
        let old = now.addingTimeInterval(-7200)     // 2h ago — before cutoff

        seedStats([
            HistoryStatsEntry(id: UUID(), date: recent, wordCount: 2, duration: 1.0),
            HistoryStatsEntry(id: UUID(), date: old, wordCount: 7, duration: 1.0),
        ])

        let filtered = service.statsEntries(since: cutoff)

        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.wordCount, 2)
    }

    func testTotalsAggregateAcrossMultipleEntries() {
        service.addItem(transcript: "one two three", duration: 4.0)
        service.addItem(transcript: "four five", duration: 6.0)

        XCTAssertEqual(service.transcriptionCount(), 2)
        XCTAssertEqual(service.totalWordCount(), 5)
        XCTAssertEqual(service.totalDuration(), 10.0)
    }

    func testTotalDurationSinceFiltersOutOldEntries() {
        let now = Date()
        let cutoff = now.addingTimeInterval(-3600)

        seedStats([
            HistoryStatsEntry(id: UUID(), date: now.addingTimeInterval(-60),
                              wordCount: 2, duration: 5.0),
            HistoryStatsEntry(id: UUID(), date: now.addingTimeInterval(-7200),
                              wordCount: 3, duration: 9.0),
        ])

        XCTAssertEqual(service.totalDuration(since: cutoff), 5.0)
        XCTAssertEqual(service.transcriptionCount(since: cutoff), 1)
    }

    func testZeroWordEntryContributesNothingToTotalWordCount() {
        let now = Date()
        seedStats([
            HistoryStatsEntry(id: UUID(), date: now, wordCount: 0, duration: 2.0),
            HistoryStatsEntry(id: UUID(), date: now, wordCount: 4, duration: 3.0),
        ])

        XCTAssertEqual(service.totalWordCount(), 4)
        // Zero-word entry still counts as a transcription and contributes duration.
        XCTAssertEqual(service.transcriptionCount(), 2)
        XCTAssertEqual(service.totalDuration(), 5.0)
    }

    // MARK: - migrateStatsIfNeeded

    func testMigrateStatsBuildsStatsFromHistoryWhenStatsAbsent() throws {
        let now = Date()
        let history = [
            HistoryItem(id: UUID(), date: now, transcript: "alpha beta gamma",
                        duration: 3.0, audioFileURL: nil, modelUsed: nil,
                        transcriptionTime: nil),
            HistoryItem(id: UUID(), date: now, transcript: "delta",
                        duration: 1.0, audioFileURL: nil, modelUsed: nil,
                        transcriptionTime: nil),
        ]
        let encoded = try JSONEncoder().encode(history)
        UserDefaults.standard.set(encoded, forKey: "history_items")
        // No stats store present.
        UserDefaults.standard.removeObject(forKey: "history_stats_entries")

        service.reloadFromPersistenceForTesting()

        XCTAssertEqual(service.statsEntries.count, 2)
        XCTAssertEqual(service.totalWordCount(), 4) // 3 + 1
        XCTAssertEqual(service.totalDuration(), 4.0)
    }

    func testMigrateStatsNoOpsWhenStatsAlreadyExist() throws {
        let now = Date()
        let history = [
            HistoryItem(id: UUID(), date: now, transcript: "alpha beta gamma",
                        duration: 3.0, audioFileURL: nil, modelUsed: nil,
                        transcriptionTime: nil),
        ]
        // Pre-existing stats that deliberately disagree with the history above.
        let existingStats = [
            HistoryStatsEntry(id: UUID(), date: now, wordCount: 99, duration: 50.0),
        ]
        UserDefaults.standard.set(try JSONEncoder().encode(history), forKey: "history_items")
        UserDefaults.standard.set(try JSONEncoder().encode(existingStats),
                                  forKey: "history_stats_entries")

        service.reloadFromPersistenceForTesting()

        // Migration must not overwrite existing stats.
        XCTAssertEqual(service.statsEntries.count, 1)
        XCTAssertEqual(service.totalWordCount(), 99)
        XCTAssertEqual(service.totalDuration(), 50.0)
    }

    func testMigrateStatsNoOpsWhenHistoryEmpty() {
        UserDefaults.standard.removeObject(forKey: "history_items")
        UserDefaults.standard.removeObject(forKey: "history_stats_entries")

        service.reloadFromPersistenceForTesting()

        XCTAssertTrue(service.statsEntries.isEmpty)
        XCTAssertEqual(service.totalWordCount(), 0)
    }
}
