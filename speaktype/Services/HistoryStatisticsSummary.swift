import Foundation

/// A compact, calendar-aware snapshot built once when history changes, never
/// while SwiftUI lays out a chart or an audio meter publishes another sample.
nonisolated struct HistoryStatisticsSummary: Sendable {
    struct Totals: Sendable {
        var count = 0
        var words = 0
        var duration: TimeInterval = 0

        mutating func add(_ entry: HistoryStatsEntry) {
            count += 1
            words += entry.wordCount
            duration += entry.duration
        }
    }

    var total = Totals()
    var days: [Date: Totals] = [:]

    static func build(_ entries: [HistoryStatsEntry], calendar: Calendar) -> Self {
        var result = Self()
        for entry in entries {
            result.total.add(entry)
            result.days[calendar.startOfDay(for: entry.date), default: Totals()].add(entry)
        }
        return result
    }

    func period(_ period: StatisticsPeriod, now: Date, calendar: Calendar) -> HistoryPeriodSummary {
        let dayCount = period == .week ? 7 : period == .month ? 30 : 365
        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(dayCount - 1), to: end) ?? end
        var totals = Totals()
        var buckets: [Date: Int] = [:]
        var day = start
        while day <= end {
            let values = days[day] ?? Totals()
            totals.count += values.count
            totals.words += values.words
            totals.duration += values.duration
            let bucket = period == .year
                ? calendar.date(from: calendar.dateComponents([.year, .month], from: day)) ?? day
                : day
            buckets[bucket, default: 0] += values.words
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            day = next
        }
        let data = buckets.keys.sorted().map {
            DailyWordCount(date: $0, wordCount: buckets[$0] ?? 0, isMonthly: period == .year)
        }
        return HistoryPeriodSummary(start: start, totals: totals, data: data)
    }
}

nonisolated struct HistoryPeriodSummary: Sendable {
    var start = Date.distantPast
    var totals = HistoryStatisticsSummary.Totals()
    var data: [DailyWordCount] = []
}

/// Calendar changes and revisions invalidate the snapshot. Playback ticks do not.
nonisolated struct HistorySummaryRequest: Hashable {
    let revision: Int
    let day: Date
    let timeZone: String
    let period: String

    init(revision: Int, now: Date, calendar: Calendar = .current, period: String = "") {
        self.revision = revision
        day = calendar.startOfDay(for: now)
        timeZone = calendar.timeZone.identifier
        self.period = period
    }
}
