import Foundation
import Combine
import SwiftUI // For IndexSet operations if needed, though Foundation usually covers it, but error says missing import.

nonisolated struct HistoryStatsEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let date: Date
    let wordCount: Int
    let duration: TimeInterval
}

nonisolated struct HistoryItem: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let date: Date
    let transcript: String
    let duration: TimeInterval
    let audioFileURL: URL?
    let modelUsed: String?
    let transcriptionTime: TimeInterval?
    /// ISO code the engine decoded with. Optional so entries saved before this
    /// existed still decode (a missing key reads as nil).
    let detectedLanguage: String?

    /// Explicit so `detectedLanguage` can default, leaving existing call sites
    /// unchanged.
    init(
        id: UUID, date: Date, transcript: String, duration: TimeInterval,
        audioFileURL: URL? = nil, modelUsed: String? = nil,
        transcriptionTime: TimeInterval? = nil, detectedLanguage: String? = nil
    ) {
        self.id = id
        self.date = date
        self.transcript = transcript
        self.duration = duration
        self.audioFileURL = audioFileURL
        self.modelUsed = modelUsed
        self.transcriptionTime = transcriptionTime
        self.detectedLanguage = detectedLanguage
    }

    var wordCount: Int {
        transcript.split(whereSeparator: { $0.isWhitespace }).count
    }

    var preview: String {
        String(transcript.prefix(240))
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: HistoryItem, rhs: HistoryItem) -> Bool {
        lhs.id == rhs.id
    }
}

/// The observable facade retains only the newest page of transcripts. Database
/// work runs on SQLiteHistoryStore's actor and queued mutations preserve call order.
@MainActor
final class HistoryService: ObservableObject {
    static let shared = HistoryService()

    @Published private(set) var items: [HistoryItem] = []
    @Published private(set) var totalItemCount = 0
    @Published private(set) var statsEntries: [HistoryStatsEntry] = []
    @Published private(set) var isLoading = true
    @Published private(set) var errorMessage: String?
    @Published private(set) var errorRevision = 0
    @Published private(set) var revision = 0

    private let store: SQLiteHistoryStore
    private var pending: Task<Void, Never>?

    init(databaseURL: URL? = nil, defaults: UserDefaults = .standard) {
        let url = databaseURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeakType", isDirectory: true)
            .appendingPathComponent("history.sqlite")
        store = SQLiteHistoryStore(databaseURL: url, defaults: defaults)
        enqueue { _ in }
    }

    func waitUntilReady() async { await pending?.value }

    /// Waits until every operation queued before this call is durably committed.
    /// Failure is exposed through errorMessage and never silently discarded.
    func flush() async { await pending?.value }

    func query(search: String = "", limit: Int = 50, offset: Int = 0) async throws -> HistoryPage {
        await pending?.value
        return try await store.query(search: search, limit: limit, offset: offset)
    }

    func query(search: String = "", limit: Int = 50, after cursor: HistoryCursor) async throws -> HistoryPage {
        await pending?.value
        return try await store.query(search: search, limit: limit, after: cursor)
    }

    func retryLoading() {
        isLoading = true
        enqueue { _ in }
    }

    func addItem(transcript: String, duration: TimeInterval, audioFileURL: URL? = nil,
                 modelUsed: String? = nil, transcriptionTime: TimeInterval? = nil,
                 detectedLanguage: String? = nil) {
        let normalized = WhisperService.normalizedTranscription(from: transcript)
        guard !normalized.isEmpty else { return }
        let item = HistoryItem(id: UUID(), date: Date(), transcript: normalized,
            duration: duration, audioFileURL: audioFileURL, modelUsed: modelUsed,
            transcriptionTime: transcriptionTime, detectedLanguage: detectedLanguage)
        enqueue { try await $0.add(item) }
    }

    func updateTranscript(id: UUID, transcript: String, modelUsed: String? = nil,
                          transcriptionTime: TimeInterval? = nil) {
        let normalized = WhisperService.normalizedTranscription(from: transcript)
        guard !normalized.isEmpty else { return }
        enqueue { try await $0.update(id: id, transcript: normalized,
            modelUsed: modelUsed, transcriptionTime: transcriptionTime) }
    }

    func deleteItem(at offsets: IndexSet, deleteAudioFile: Bool = true) {
        let ids = offsets.compactMap { items.indices.contains($0) ? items[$0].id : nil }
        for id in ids { deleteItem(id: id, deleteAudioFile: deleteAudioFile) }
    }

    func deleteItem(id: UUID, deleteAudioFile: Bool = true) {
        enqueue { try await $0.delete(id: id, deleteAudioFile: deleteAudioFile) }
    }

    func clearAll() { enqueue { try await $0.clear() } }

    private func enqueue(_ operation: @escaping @Sendable (SQLiteHistoryStore) async throws -> Void) {
        let previous = pending
        let store = store
        pending = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try await operation(store)
                let snapshot = try await store.snapshot()
                self.apply(snapshot)
                self.errorMessage = nil
            } catch {
                // Deleting an audio file can fail after its transcript is already
                // committed. Reflect durable state while retaining the error.
                if let snapshot = try? await store.snapshot() { self.apply(snapshot) }
                self.errorRevision += 1
                self.errorMessage = error.localizedDescription
            }
            self.isLoading = false
        }
    }

    private func apply(_ snapshot: HistoryStoreSnapshot) {
        items = snapshot.page.items
        totalItemCount = snapshot.page.totalCount
        statsEntries = snapshot.stats
        revision += 1
    }

    func totalWordCount() -> Int { statsEntries.reduce(0) { $0 + $1.wordCount } }
    func transcriptionCount(since startDate: Date? = nil) -> Int { filteredStatsEntries(since: startDate).count }
    func totalDuration(since startDate: Date? = nil) -> TimeInterval {
        filteredStatsEntries(since: startDate).reduce(0) { $0 + $1.duration }
    }
    func wordCount(on day: Date, calendar: Calendar = .current) -> Int {
        statsEntries.lazy.filter { calendar.isDate($0.date, inSameDayAs: day) }.reduce(0) { $0 + $1.wordCount }
    }
    func statsEntries(since startDate: Date) -> [HistoryStatsEntry] { filteredStatsEntries(since: startDate) }
    private func filteredStatsEntries(since startDate: Date?) -> [HistoryStatsEntry] {
        guard let startDate else { return statsEntries }
        return statsEntries.filter { $0.date >= startDate }
    }
}
