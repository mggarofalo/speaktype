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
    @Published private(set) var pendingMutationCount = 0
    @Published private(set) var recoveryErrorMessage: String?

    private let store: SQLiteHistoryStore
    private let recoveryJournal: HistoryRecoveryJournal
    private let recoveryFaults: HistoryRecoveryFaults
    private var pending: Task<Void, Never>?
    private var pendingMutations: [HistoryMutation] = []
    private var mutationQueueRevision = 0
    private var journalIsReadable = false
    private var journalIsOwnedByAnotherProcess = false
    private var needsStatsRefreshAfterOwnershipTransfer = false

    init(databaseURL: URL? = nil, recoveryJournalURL: URL? = nil,
         defaults: UserDefaults = .standard,
         recoveryFaults: HistoryRecoveryFaults = .init()) {
        let url = databaseURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpeakType", isDirectory: true)
            .appendingPathComponent("history.sqlite")
        store = SQLiteHistoryStore(databaseURL: url, defaults: defaults)
        recoveryJournal = HistoryRecoveryJournal(
            fileURL: recoveryJournalURL ?? url.appendingPathExtension("pending-mutations.json"))
        self.recoveryFaults = recoveryFaults
        schedule { [weak self] in await self?.initialize() }
    }

    func waitUntilReady() async { await pending?.value }

    /// Waits until every operation queued before this call is durably committed.
    /// Save failures remain visible through recoveryErrorMessage; snapshot and
    /// load failures remain visible through errorMessage.
    func flush() async { await pending?.value }

    /// Gives retained writes one final retry and rejects termination while any
    /// mutation or unreadable recovery journal remains.
    func flushForTermination() async throws {
        await pending?.value
        if !pendingMutations.isEmpty || recoveryErrorMessage != nil {
            retryPendingWrites()
            await pending?.value
        }
        guard pendingMutations.isEmpty, recoveryErrorMessage == nil else {
            if !pendingMutations.isEmpty {
                throw HistoryRecoveryError.pendingMutations(
                    count: pendingMutations.count, message: recoveryErrorMessage)
            }
            throw HistoryRecoveryError.journalUnavailable(
                recoveryErrorMessage ?? "The journal could not be verified.")
        }
    }

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
        schedule { [weak self] in await self?.refreshSnapshot() }
    }

    func retryPendingWrites() {
        schedule { [weak self] in
            guard let self else { return }
            await self.reloadJournalAndProcessPendingWrites()
        }
    }

    func addItem(transcript: String, duration: TimeInterval, audioFileURL: URL? = nil,
                 modelUsed: String? = nil, transcriptionTime: TimeInterval? = nil,
                 detectedLanguage: String? = nil) {
        let normalized = WhisperService.normalizedTranscription(from: transcript)
        guard !normalized.isEmpty else { return }
        let item = HistoryItem(id: UUID(), date: Date(), transcript: normalized,
            duration: duration, audioFileURL: audioFileURL, modelUsed: modelUsed,
            transcriptionTime: transcriptionTime, detectedLanguage: detectedLanguage)
        enqueue(HistoryMutation(operation: .add(item)))
    }

    func updateTranscript(id: UUID, transcript: String, modelUsed: String? = nil,
                          transcriptionTime: TimeInterval? = nil) {
        let normalized = WhisperService.normalizedTranscription(from: transcript)
        guard !normalized.isEmpty else { return }
        enqueue(HistoryMutation(operation: .update(.init(
            id: id, transcript: normalized, modelUsed: modelUsed,
            transcriptionTime: transcriptionTime))))
    }

    func deleteItem(at offsets: IndexSet, deleteAudioFile: Bool = true) {
        let ids = offsets.compactMap { items.indices.contains($0) ? items[$0].id : nil }
        for id in ids { deleteItem(id: id, deleteAudioFile: deleteAudioFile) }
    }

    func deleteItem(id: UUID, deleteAudioFile: Bool = true) {
        enqueue(HistoryMutation(operation: .delete(.init(
            id: id, deleteAudioFile: deleteAudioFile))))
    }

    func clearAll() { enqueue(HistoryMutation(operation: .clear)) }

    private func initialize() async {
        do {
            let recovered = try await recoveryJournal.load()
            journalIsReadable = true
            journalIsOwnedByAnotherProcess = false
            mergeRecoveredMutations(recovered)
            await processPendingWrites()
            try? await store.pruneAppliedOperations(keeping: Set(pendingMutations.map(\.id)))
        } catch {
            journalIsReadable = false
            handleJournalLoadFailure(error)
            await refreshSnapshot()
        }
    }

    private func enqueue(_ mutation: HistoryMutation) {
        pendingMutations.append(mutation)
        mutationQueueRevision += 1
        pendingMutationCount = pendingMutations.count
        if journalIsOwnedByAnotherProcess {
            recordRecoveryError(HistoryRecoveryError.journalInUse)
        }
        schedule { [weak self] in await self?.processPendingWrites() }
    }

    private func schedule(_ operation: @escaping @MainActor () async -> Void) {
        let previous = pending
        pending = Task {
            await previous?.value
            await operation()
        }
    }

    private func reloadJournalAndProcessPendingWrites() async {
        do {
            let recovered = try await recoveryJournal.reload()
            journalIsReadable = true
            journalIsOwnedByAnotherProcess = false
            if needsStatsRefreshAfterOwnershipTransfer {
                do {
                    try await store.reloadCachedStats()
                    needsStatsRefreshAfterOwnershipTransfer = false
                } catch {
                    // The journal was read but its recovered operations have not
                    // been merged yet. Keep writes disabled so a RAM-only queue
                    // cannot replace that on-disk queue before a full retry.
                    journalIsReadable = false
                    recordRecoveryError(error)
                    await refreshSnapshot()
                    return
                }
            }
            mergeRecoveredMutations(recovered)
            await processPendingWrites()
            try? await store.pruneAppliedOperations(keeping: Set(pendingMutations.map(\.id)))
        } catch {
            journalIsReadable = false
            handleJournalLoadFailure(error)
            await refreshSnapshot()
        }
    }

    /// Drains the FIFO until its first failure. Later deletes and clears cannot
    /// overtake an earlier failed save.
    private func processPendingWrites() async {
        guard journalIsReadable else { return }

        while let mutation = pendingMutations.first {
            do {
                try await persistCurrentQueue()
                // persistCurrentQueue may suspend while another mutation is
                // enqueued. It loops until the whole current queue is durable.
                guard pendingMutations.first?.id == mutation.id else { continue }

                try await store.apply(mutation)
                try await recoveryFaults.afterApplyingMutation?(mutation)

                try await removeCommittedHeadFromJournal(mutation)

                // Journal cleanup is the safety boundary. A failed ledger
                // retirement leaves only a harmless stale replay marker.
                try? await store.retireAppliedOperation(id: mutation.id)
            } catch {
                // Include mutations that arrived while SQLite or the fault seam
                // was suspended. If this write also fails, RAM remains the source
                // of truth and no later SQL operation is attempted.
                do {
                    try await persistCurrentQueue()
                } catch {
                    recordRecoveryError(error)
                    await refreshSnapshot()
                    return
                }
                recordRecoveryError(error)
                await refreshSnapshot()
                return
            }
        }

        recoveryErrorMessage = nil
        await refreshSnapshot()
    }

    private func persistCurrentQueue() async throws {
        while true {
            let revision = mutationQueueRevision
            let snapshot = pendingMutations
            try await recoveryJournal.replace(with: snapshot)
            if revision == mutationQueueRevision { return }
        }
    }

    private func removeCommittedHeadFromJournal(_ mutation: HistoryMutation) async throws {
        while true {
            let revision = mutationQueueRevision
            let remaining = Array(pendingMutations.dropFirst())
            try await recoveryJournal.replace(with: remaining)
            // A new mutation may arrive while cleanup awaits the journal actor.
            // Rewrite the remaining queue before advancing so the cleanup of the
            // committed head never erases a newer durable snapshot.
            guard revision == mutationQueueRevision else { continue }
            guard pendingMutations.first?.id == mutation.id else { return }
            pendingMutations.removeFirst()
            mutationQueueRevision += 1
            pendingMutationCount = pendingMutations.count
            return
        }
    }

    private func mergeRecoveredMutations(_ recovered: [HistoryMutation]) {
        let recoveredIDs = Set(recovered.map(\.id))
        // Journal entries predate any RAM-only work queued while the file was
        // unreadable. Stable operation IDs remove the overlap on normal reloads.
        pendingMutations = recovered + pendingMutations.filter { !recoveredIDs.contains($0.id) }
        mutationQueueRevision += 1
        pendingMutationCount = pendingMutations.count
    }

    private func refreshSnapshot() async {
        do {
            apply(try await store.snapshot())
            errorMessage = nil
        } catch {
            errorRevision += 1
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func recordRecoveryError(_ error: Error) {
        recoveryErrorMessage = error.localizedDescription
    }

    private func handleJournalLoadFailure(_ error: Error) {
        if case HistoryRecoveryError.journalInUse = error {
            journalIsOwnedByAnotherProcess = true
            needsStatsRefreshAfterOwnershipTransfer = true
            if !pendingMutations.isEmpty { recordRecoveryError(error) }
        } else {
            journalIsOwnedByAnotherProcess = false
            recordRecoveryError(error)
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
