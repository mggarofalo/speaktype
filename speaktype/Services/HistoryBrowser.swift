import Combine
import Foundation

@MainActor
final class HistoryBrowser: ObservableObject {
    static let pageSize = 50

    @Published private(set) var rows: [HistoryRow] = []
    @Published private(set) var totalCount = 0
    @Published private(set) var offset = 0
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var searchText = ""

    private let historyService: HistoryService
    private var requestID = 0

    init(historyService: HistoryService) {
        self.historyService = historyService
    }

    convenience init() { self.init(historyService: .shared) }

    var pageNumber: Int { totalCount == 0 ? 0 : offset / Self.pageSize + 1 }
    var pageCount: Int { max(1, Int(ceil(Double(totalCount) / Double(Self.pageSize)))) }
    var canGoBack: Bool { offset > 0 }
    var canGoForward: Bool { offset + Self.pageSize < totalCount }

    func loadInitialPage() async {
        await load(offset: 0, waitForService: true)
    }

    func refresh() async {
        let validOffset = totalCount == 0 ? 0 : min(offset, ((totalCount - 1) / Self.pageSize) * Self.pageSize)
        await load(offset: validOffset)
    }

    func search() async { await load(offset: 0) }

    func previousPage() async {
        guard canGoBack else { return }
        await load(offset: max(0, offset - Self.pageSize))
    }

    func nextPage() async {
        guard canGoForward else { return }
        await load(offset: offset + Self.pageSize)
    }

    func resetToFirstPage() {
        offset = 0
        rows = []
        totalCount = 0
    }

    private func load(offset requestedOffset: Int, waitForService: Bool = false) async {
        requestID += 1
        let currentRequestID = requestID
        let requestedSearch = searchText
        isLoading = true
        errorMessage = nil
        do {
            if waitForService { await historyService.waitUntilReady() }
            var page = try await historyService.query(
                search: requestedSearch, limit: Self.pageSize, offset: requestedOffset)

            // A deletion can make the current final page disappear after we chose
            // its offset. Re-query the final valid page instead of leaving a
            // non-empty history with an empty, stranded page.
            var resolvedOffset = requestedOffset
            if page.items.isEmpty, page.totalCount > 0, requestedOffset >= page.totalCount {
                resolvedOffset = ((page.totalCount - 1) / Self.pageSize) * Self.pageSize
                page = try await historyService.query(
                    search: requestedSearch, limit: Self.pageSize, offset: resolvedOffset)
            }

            guard currentRequestID == requestID, requestedSearch == searchText else { return }
            let fetchedRows = await Task.detached(priority: .userInitiated) {
                page.items.map(HistoryRow.init)
            }.value
            guard currentRequestID == requestID, requestedSearch == searchText else { return }
            rows = fetchedRows
            totalCount = page.totalCount
            offset = resolvedOffset
            isLoading = false
        } catch is CancellationError {
            guard currentRequestID == requestID else { return }
            isLoading = false
        } catch {
            guard currentRequestID == requestID else { return }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func dismissError() { errorMessage = nil }
}

/// Presentation work happens once per fetched item instead of on every SwiftUI redraw.
struct HistoryRow: Identifiable, Sendable {
    let item: HistoryItem
    let preview: String
    let wordCount: Int

    var id: UUID { item.id }

    nonisolated init(item: HistoryItem) {
        self.item = item
        let compactText = item.transcript
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        wordCount = compactText.split(separator: " ").count
        preview = String(compactText.prefix(280))
    }
}
