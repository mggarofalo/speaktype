import Foundation
import SQLite3
import Darwin

nonisolated struct HistoryPage: Sendable {
    let items: [HistoryItem]
    let totalCount: Int
}

nonisolated struct HistoryCursor: Sendable {
    let date: Date
    let id: UUID
}

nonisolated struct HistoryStoreSnapshot: Sendable {
    let page: HistoryPage
    let stats: [HistoryStatsEntry]
}

nonisolated enum HistoryStoreError: LocalizedError {
    case database(String)
    case invalidRecord

    var errorDescription: String? {
        switch self {
        case .database(let message): return "History storage: \(message)"
        case .invalidRecord: return "A saved history entry could not be read."
        }
    }
}

/// All SQLite work, including migration and JSON coding, is isolated from the UI.
/// Methods contain no suspension points, so transactions cannot interleave.
actor SQLiteHistoryStore {
    private var database: OpaquePointer?
    private let databaseURL: URL
    private let defaults: UserDefaults
    private var initialized = false
    private var cachedStats: [HistoryStatsEntry] = []

    init(databaseURL: URL, defaults: UserDefaults) {
        self.databaseURL = databaseURL
        self.defaults = defaults
    }

    deinit { if let database { sqlite3_close(database) } }

    func initialize() throws {
        guard !initialized else { return }
        if database == nil {
            try FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var handle: OpaquePointer?
            let status = sqlite3_open_v2(databaseURL.path, &handle,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
            guard status == SQLITE_OK, let handle else {
                let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Cannot open database"
                if let handle { sqlite3_close(handle) }
                throw HistoryStoreError.database(message)
            }
            database = handle
            sqlite3_busy_timeout(handle, 5000)
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("""
            CREATE TABLE IF NOT EXISTS history (
                id TEXT PRIMARY KEY, date REAL NOT NULL, transcript TEXT NOT NULL,
                search_text TEXT NOT NULL, payload BLOB NOT NULL)
            """)
        try execute("CREATE INDEX IF NOT EXISTS history_date_id ON history(date DESC, id DESC)")
        try execute("""
            CREATE TABLE IF NOT EXISTS stats (
                id TEXT PRIMARY KEY, date REAL NOT NULL, words INTEGER NOT NULL,
                duration REAL NOT NULL, reference_date REAL)
            """)
        // Unix seconds remain the indexed query value. Preserve Date's native
        // reference timestamp too: adding/subtracting the epoch offset rounds
        // submicrosecond values and breaks exact metadata round trips.
        let hasReferenceDate = try withStatement("PRAGMA table_info(stats)") { statement in
            while try next(statement) {
                if let name = sqlite3_column_text(statement, 1), String(cString: name) == "reference_date" { return true }
            }
            return false
        }
        if !hasReferenceDate { try execute("ALTER TABLE stats ADD COLUMN reference_date REAL") }
        try execute("CREATE INDEX IF NOT EXISTS stats_date ON stats(date DESC)")
        try execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        try execute("""
            CREATE TABLE IF NOT EXISTS applied_history_operations (
                id TEXT PRIMARY KEY,
                applied_at REAL NOT NULL,
                audio_path TEXT,
                audio_device INTEGER,
                audio_inode INTEGER,
                audio_birth_seconds INTEGER,
                audio_birth_nanoseconds INTEGER,
                audio_cleanup_done INTEGER NOT NULL DEFAULT 0)
            """)
        let operationColumns: [(String, String)] = [
            ("audio_path", "TEXT"),
            ("audio_device", "INTEGER"),
            ("audio_inode", "INTEGER"),
            ("audio_birth_seconds", "INTEGER"),
            ("audio_birth_nanoseconds", "INTEGER"),
            ("audio_cleanup_done", "INTEGER NOT NULL DEFAULT 0")
        ]
        for (name, declaration) in operationColumns {
            let exists = try hasColumn(name, in: "applied_history_operations")
            if !exists {
                try execute("ALTER TABLE applied_history_operations ADD COLUMN \(name) \(declaration)")
            }
        }
        try migrateLegacyIfNeeded()
        cachedStats = try readStats()
        initialized = true
    }

    private func migrateLegacyIfNeeded() throws {
        try transaction {
            // Check inside the write transaction: another window/process may have migrated.
            guard try scalar("SELECT COUNT(*) FROM metadata WHERE key='legacy_import_v1'") == 0 else { return }
            let decoder = JSONDecoder()
            let history = try defaults.data(forKey: "history_items").map {
                try decoder.decode([HistoryItem].self, from: $0)
            } ?? []
            let savedStats = try defaults.data(forKey: "history_stats_entries").map {
                try decoder.decode([HistoryStatsEntry].self, from: $0)
            }
            // Preserve every historical field exactly; changing current cleanup settings
            // must never rewrite a previously saved transcript during a migration.
            for item in history { try insert(item) }
            let stats = savedStats.flatMap { $0.isEmpty ? nil : $0 } ?? history.map {
                HistoryStatsEntry(id: $0.id, date: $0.date,
                    wordCount: $0.wordCount, duration: $0.duration)
            }
            for entry in stats { try insertStats(entry) }
            try execute("INSERT INTO metadata VALUES ('legacy_import_v1', 'complete')")
        }
        // The old defaults are deliberately retained as a recovery copy. The
        // transaction marker prevents deleted entries being imported on restart.
    }

    func snapshot() throws -> HistoryStoreSnapshot {
        try initialize()
        return try HistoryStoreSnapshot(page: query(limit: 50), stats: cachedStats)
    }

    /// Another app instance may commit while this store is limited to read-only
    /// browsing by the recovery-journal lease. Refresh once when ownership later
    /// transfers, before applying this instance's retained mutations.
    func reloadCachedStats() throws {
        try initialize()
        cachedStats = try readStats()
    }

    func query(search: String = "", limit: Int = 50, offset: Int = 0,
               after cursor: HistoryCursor? = nil) throws -> HistoryPage {
        try initialize()
        let folded = Self.searchText(search.trimmingCharacters(in: .whitespacesAndNewlines))
        let clause = folded.isEmpty ? "" : " WHERE search_text LIKE ? ESCAPE '\\'"
        let pattern = "%" + folded.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
        let total = try withStatement("SELECT COUNT(*) FROM history" + clause) { stmt in
            if !folded.isEmpty { try bind(pattern, to: stmt, at: 1) }
            try stepRow(stmt)
            return Int(sqlite3_column_int64(stmt, 0))
        }
        var conditions = clause
        if cursor != nil { conditions += (conditions.isEmpty ? " WHERE " : " AND ") + "(date < ? OR (date = ? AND id < ?))" }
        let items = try withStatement("SELECT payload FROM history" + conditions + " ORDER BY date DESC, id DESC LIMIT ? OFFSET ?") { stmt in
            var index: Int32 = 1
            if !folded.isEmpty { try bind(pattern, to: stmt, at: index); index += 1 }
            if let cursor {
                sqlite3_bind_double(stmt, index, cursor.date.timeIntervalSince1970); index += 1
                sqlite3_bind_double(stmt, index, cursor.date.timeIntervalSince1970); index += 1
                try bind(cursor.id.uuidString, to: stmt, at: index); index += 1
            }
            sqlite3_bind_int64(stmt, index, Int64(max(1, min(limit, 500)))); index += 1
            sqlite3_bind_int64(stmt, index, Int64(max(0, offset)))
            var items: [HistoryItem] = []
            while try next(stmt) { items.append(try decodeItem(stmt)) }
            return items
        }
        return HistoryPage(items: items, totalCount: total)
    }

    /// Applies a mutation and records its operation ID in the same transaction.
    /// Replaying a committed ID skips database, cache, and filesystem changes.
    /// Audio cleanup is attempted once so replay cannot delete a new file that
    /// later appears at the same path.
    func apply(_ mutation: HistoryMutation) throws {
        try initialize()
        let outcome = try transaction { try applyInTransaction(mutation) }

        if outcome.wasNewlyApplied, let statsEntry = outcome.statsEntry {
            upsertCachedStats(statsEntry)
        }

        if let audioCleanup = outcome.audioCleanup {
            try finishAudioCleanup(audioCleanup, operationID: mutation.id)
        }
    }

    // Kept as small compatibility helpers for store-level callers. Service
    // mutations use apply(_:) so their operation IDs survive a restart.
    func add(_ item: HistoryItem) throws {
        try apply(HistoryMutation(operation: .add(item)))
    }

    func update(id: UUID, transcript: String, modelUsed: String?, transcriptionTime: TimeInterval?) throws {
        try apply(HistoryMutation(operation: .update(.init(
            id: id, transcript: transcript, modelUsed: modelUsed,
            transcriptionTime: transcriptionTime))))
    }

    func delete(id: UUID, deleteAudioFile: Bool) throws {
        try apply(HistoryMutation(operation: .delete(.init(
            id: id, deleteAudioFile: deleteAudioFile))))
    }

    func clear() throws {
        try apply(HistoryMutation(operation: .clear))
    }

    /// Ledger rows are needed only while their operation remains in a readable
    /// recovery journal. This cleanup is deliberately separate from apply: the
    /// journal must remove an operation before its replay marker can disappear.
    func retireAppliedOperation(id: UUID) throws {
        try initialize()
        try withStatement("DELETE FROM applied_history_operations WHERE id=?") { stmt in
            try bind(id.uuidString, to: stmt, at: 1)
            try stepDone(stmt)
        }
    }

    func pruneAppliedOperations(keeping activeIDs: Set<UUID>) throws {
        try initialize()
        let staleIDs = try withStatement("SELECT id FROM applied_history_operations") { stmt in
            var ids: [String] = []
            while try next(stmt) {
                guard let text = sqlite3_column_text(stmt, 0) else {
                    throw HistoryStoreError.invalidRecord
                }
                let value = String(cString: text)
                guard let id = UUID(uuidString: value) else {
                    throw HistoryStoreError.invalidRecord
                }
                if !activeIDs.contains(id) { ids.append(value) }
            }
            return ids
        }
        guard !staleIDs.isEmpty else { return }
        try transaction {
            for id in staleIDs {
                try withStatement("DELETE FROM applied_history_operations WHERE id=?") { stmt in
                    try bind(id, to: stmt, at: 1)
                    try stepDone(stmt)
                }
            }
        }
    }

    private struct MutationOutcome {
        let wasNewlyApplied: Bool
        let statsEntry: HistoryStatsEntry?
        let audioCleanup: AudioCleanup?
    }

    private struct AudioCleanup {
        let path: String
        let device: UInt64
        let inode: UInt64
        let birthSeconds: Int64
        let birthNanoseconds: Int64
    }

    private struct FileIdentity {
        let device: UInt64
        let inode: UInt64
        let birthSeconds: Int64
        let birthNanoseconds: Int64
    }

    private struct AppliedOperation {
        let audioCleanup: AudioCleanup?
    }

    private func applyInTransaction(_ mutation: HistoryMutation) throws -> MutationOutcome {
        if let applied = try appliedOperation(id: mutation.id) {
            return MutationOutcome(wasNewlyApplied: false, statsEntry: nil,
                                   audioCleanup: applied.audioCleanup)
        }

        var statsEntry: HistoryStatsEntry?
        var audioCleanup: AudioCleanup?
        switch mutation.operation {
        case .add(let item):
            try insert(item)
            let entry = HistoryStatsEntry(id: item.id, date: item.date,
                wordCount: item.wordCount, duration: item.duration)
            try insertStats(entry)
            statsEntry = entry

        case .update(let update):
            if let item = try item(id: update.id) {
                let updated = HistoryItem(id: item.id, date: item.date,
                    transcript: update.transcript, duration: item.duration,
                    audioFileURL: item.audioFileURL,
                    modelUsed: update.modelUsed ?? item.modelUsed,
                    transcriptionTime: update.transcriptionTime ?? item.transcriptionTime,
                    detectedLanguage: item.detectedLanguage)
                try insert(updated)
                try withStatement("UPDATE stats SET words=? WHERE id=?") { stmt in
                    sqlite3_bind_int64(stmt, 1, Int64(updated.wordCount))
                    try bind(update.id.uuidString, to: stmt, at: 2)
                    try stepDone(stmt)
                }
                if sqlite3_changes(database) > 0,
                   let existing = cachedStats.first(where: { $0.id == updated.id }) {
                    // Saved statistics may intentionally differ from transcript
                    // metadata after legacy migration. Updating text changes only
                    // the word count in SQLite, so preserve the cached date and
                    // duration here as well.
                    statsEntry = HistoryStatsEntry(id: existing.id, date: existing.date,
                        wordCount: updated.wordCount, duration: existing.duration)
                }
            }

        case .delete(let deletion):
            if deletion.deleteAudioFile,
               let path = try item(id: deletion.id)?.audioFileURL?.path {
                audioCleanup = try Self.fileIdentity(atPath: path).map {
                    AudioCleanup(path: path, device: $0.device, inode: $0.inode,
                        birthSeconds: $0.birthSeconds,
                        birthNanoseconds: $0.birthNanoseconds)
                }
            }
            try withStatement("DELETE FROM history WHERE id=?") { stmt in
                try bind(deletion.id.uuidString, to: stmt, at: 1)
                try stepDone(stmt)
            }

        case .clear:
            try execute("DELETE FROM history")
        }

        try withStatement("""
            INSERT INTO applied_history_operations (
                id,applied_at,audio_path,audio_device,audio_inode,
                audio_birth_seconds,audio_birth_nanoseconds,audio_cleanup_done)
            VALUES (?,?,?,?,?,?,?,?)
            """) { stmt in
            try bind(mutation.id.uuidString, to: stmt, at: 1)
            sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970)
            if let audioCleanup {
                try bind(audioCleanup.path, to: stmt, at: 3)
                sqlite3_bind_int64(stmt, 4, Int64(bitPattern: audioCleanup.device))
                sqlite3_bind_int64(stmt, 5, Int64(bitPattern: audioCleanup.inode))
                sqlite3_bind_int64(stmt, 6, audioCleanup.birthSeconds)
                sqlite3_bind_int64(stmt, 7, audioCleanup.birthNanoseconds)
                sqlite3_bind_int(stmt, 8, 0)
            } else {
                for index in 3...7 { sqlite3_bind_null(stmt, Int32(index)) }
                sqlite3_bind_int(stmt, 8, 1)
            }
            try stepDone(stmt)
        }
        return MutationOutcome(wasNewlyApplied: true, statsEntry: statsEntry,
                               audioCleanup: audioCleanup)
    }

    private func appliedOperation(id: UUID) throws -> AppliedOperation? {
        try withStatement("""
            SELECT audio_path,audio_device,audio_inode,audio_birth_seconds,
                   audio_birth_nanoseconds,audio_cleanup_done
            FROM applied_history_operations WHERE id=?
            """) { stmt in
            try bind(id.uuidString, to: stmt, at: 1)
            guard try next(stmt) else { return nil }
            guard sqlite3_column_int(stmt, 5) == 0,
                  let pathText = sqlite3_column_text(stmt, 0),
                  sqlite3_column_type(stmt, 1) != SQLITE_NULL,
                  sqlite3_column_type(stmt, 2) != SQLITE_NULL,
                  sqlite3_column_type(stmt, 3) != SQLITE_NULL,
                  sqlite3_column_type(stmt, 4) != SQLITE_NULL else {
                return AppliedOperation(audioCleanup: nil)
            }
            return AppliedOperation(audioCleanup: AudioCleanup(
                path: String(cString: pathText),
                device: UInt64(bitPattern: sqlite3_column_int64(stmt, 1)),
                inode: UInt64(bitPattern: sqlite3_column_int64(stmt, 2)),
                birthSeconds: sqlite3_column_int64(stmt, 3),
                birthNanoseconds: sqlite3_column_int64(stmt, 4)))
        }
    }

    private func finishAudioCleanup(_ cleanup: AudioCleanup, operationID: UUID) throws {
        if let current = try Self.fileIdentity(atPath: cleanup.path),
           current.device == cleanup.device,
           current.inode == cleanup.inode,
           current.birthSeconds == cleanup.birthSeconds,
           current.birthNanoseconds == cleanup.birthNanoseconds {
            try FileManager.default.removeItem(atPath: cleanup.path)
        }
        // A missing path or different identity means the original file is gone.
        // Mark cleanup complete before journal retirement so replay never removes
        // an unrelated replacement at the same path.
        try withStatement("""
            UPDATE applied_history_operations SET audio_cleanup_done=1 WHERE id=?
            """) { stmt in
            try bind(operationID.uuidString, to: stmt, at: 1)
            try stepDone(stmt)
        }
    }

    private static func fileIdentity(atPath path: String) throws -> FileIdentity? {
        var information = stat()
        if path.withCString({ lstat($0, &information) }) != 0 {
            if errno == ENOENT { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return FileIdentity(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            birthSeconds: Int64(information.st_birthtimespec.tv_sec),
            birthNanoseconds: Int64(information.st_birthtimespec.tv_nsec))
    }

    private func hasColumn(_ column: String, in table: String) throws -> Bool {
        try withStatement("PRAGMA table_info(\(table))") { statement in
            while try next(statement) {
                if let name = sqlite3_column_text(statement, 1),
                   String(cString: name) == column { return true }
            }
            return false
        }
    }

    private func upsertCachedStats(_ entry: HistoryStatsEntry) {
        if let index = cachedStats.firstIndex(where: { $0.id == entry.id }) {
            if cachedStats[index].date == entry.date {
                cachedStats[index] = entry
                return
            }
            cachedStats.remove(at: index)
        }

        var lowerBound = 0
        var upperBound = cachedStats.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if Self.statsEntry(cachedStats[middle], sortsBefore: entry) {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        cachedStats.insert(entry, at: lowerBound)
    }

    private static func statsEntry(_ lhs: HistoryStatsEntry,
                                   sortsBefore rhs: HistoryStatsEntry) -> Bool {
        if lhs.date != rhs.date { return lhs.date > rhs.date }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    private func item(id: UUID) throws -> HistoryItem? {
        try withStatement("SELECT payload FROM history WHERE id=?") { stmt in
            try bind(id.uuidString, to: stmt, at: 1)
            return try next(stmt) ? decodeItem(stmt) : nil
        }
    }

    private func readStats() throws -> [HistoryStatsEntry] {
        try withStatement("SELECT id,date,words,duration,reference_date FROM stats ORDER BY date DESC,id DESC") { stmt in
            var entries: [HistoryStatsEntry] = []
            while try next(stmt) {
                guard let text = sqlite3_column_text(stmt, 0), let id = UUID(uuidString: String(cString: text)) else {
                    throw HistoryStoreError.invalidRecord
                }
                let date = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                    ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
                    : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4))
                entries.append(HistoryStatsEntry(id: id,
                    date: date,
                    wordCount: Int(sqlite3_column_int64(stmt, 2)), duration: sqlite3_column_double(stmt, 3)))
            }
            return entries
        }
    }

    private func insert(_ item: HistoryItem) throws {
        let data = try JSONEncoder().encode(item)
        try withStatement("INSERT OR REPLACE INTO history (id,date,transcript,search_text,payload) VALUES (?,?,?,?,?)") { stmt in
            try bind(item.id.uuidString, to: stmt, at: 1)
            sqlite3_bind_double(stmt, 2, item.date.timeIntervalSince1970)
            try bind(item.transcript, to: stmt, at: 3)
            try bind(Self.searchText(item.transcript), to: stmt, at: 4)
            let status = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(stmt, 5, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard status == SQLITE_OK else { throw failure() }
            try stepDone(stmt)
        }
    }

    private func insertStats(_ entry: HistoryStatsEntry) throws {
        try withStatement("INSERT OR REPLACE INTO stats (id,date,words,duration,reference_date) VALUES (?,?,?,?,?)") { stmt in
            try bind(entry.id.uuidString, to: stmt, at: 1)
            sqlite3_bind_double(stmt, 2, entry.date.timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 3, Int64(entry.wordCount))
            sqlite3_bind_double(stmt, 4, entry.duration)
            sqlite3_bind_double(stmt, 5, entry.date.timeIntervalSinceReferenceDate)
            try stepDone(stmt)
        }
    }

    private static func searchText(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private func decodeItem(_ stmt: OpaquePointer) throws -> HistoryItem {
        guard let bytes = sqlite3_column_blob(stmt, 0) else { throw HistoryStoreError.invalidRecord }
        return try JSONDecoder().decode(HistoryItem.self,
            from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0))))
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func scalar(_ sql: String) throws -> Int {
        try withStatement(sql) { stmt in
            try stepRow(stmt)
            return Int(sqlite3_column_int64(stmt, 0))
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func withStatement<T>(_ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func bind(_ value: String, to stmt: OpaquePointer, at index: Int32) throws {
        let status = value.withCString {
            sqlite3_bind_text(stmt, index, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard status == SQLITE_OK else { throw failure() }
    }

    private func next(_ stmt: OpaquePointer) throws -> Bool {
        let status = sqlite3_step(stmt)
        if status == SQLITE_ROW { return true }
        guard status == SQLITE_DONE else { throw failure() }
        return false
    }

    private func stepRow(_ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw failure() }
    }

    private func stepDone(_ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
    }

    private func failure() -> HistoryStoreError {
        .database(database.map { String(cString: sqlite3_errmsg($0)) } ?? "Database is not open")
    }
}
