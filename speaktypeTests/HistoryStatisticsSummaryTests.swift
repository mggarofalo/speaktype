import XCTest
@testable import speaktype

final class HistoryStatisticsSummaryTests: XCTestCase {
    private func calendar(_ zone: String = "America/New_York") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    func testWeekIncludesEntireFirstDayAcrossDaylightSavingTime() {
        let calendar = calendar()
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 18))!
        let firstDay = calendar.date(from: DateComponents(year: 2026, month: 3, day: 4, hour: 1))!
        let outside = calendar.date(from: DateComponents(year: 2026, month: 3, day: 3, hour: 23))!
        let entries = [
            HistoryStatsEntry(id: UUID(), date: firstDay, wordCount: 10, duration: 5),
            HistoryStatsEntry(id: UUID(), date: outside, wordCount: 90, duration: 50),
            HistoryStatsEntry(id: UUID(), date: now, wordCount: 20, duration: 7)
        ]
        let summary = HistoryStatisticsSummary.build(entries, calendar: calendar)
        let week = summary.period(.week, now: now, calendar: calendar)
        XCTAssertEqual(summary.total.words, 120)
        XCTAssertEqual(week.totals.words, 30)
        XCTAssertEqual(week.totals.count, 2)
        XCTAssertEqual(week.totals.duration, 12)
        XCTAssertEqual(week.data.count, 7)
        XCTAssertEqual(week.data.first?.wordCount, 10)
        XCTAssertEqual(week.data.last?.wordCount, 20)
    }

    func testYearCombinesMonthsWithoutLosingPeriodTotals() {
        let calendar = calendar("UTC")
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 5))!
        let entries = (1...3).map { day in
            HistoryStatsEntry(id: UUID(), date: calendar.date(from:
                DateComponents(year: 2026, month: 8, day: day))!, wordCount: day, duration: 1)
        }
        let year = HistoryStatisticsSummary.build(entries, calendar: calendar)
            .period(.year, now: now, calendar: calendar)
        XCTAssertEqual(year.totals.words, 6)
        XCTAssertEqual(year.data.reduce(0) { $0 + $1.wordCount }, 6)
        XCTAssertEqual(year.data.filter { $0.wordCount > 0 }.count, 1)
        XCTAssertTrue(year.data.allSatisfy(\.isMonthly))
        XCTAssertEqual(Set(year.data.map(\.id)).count, year.data.count)
    }

    func testCalendarBoundaryChangesDayGrouping() {
        let utc = calendar("UTC")
        let eastern = calendar()
        let date = utc.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 2))!
        let entries = [HistoryStatsEntry(id: UUID(), date: date, wordCount: 5, duration: 1)]
        let local = HistoryStatisticsSummary.build(entries, calendar: eastern)
        XCTAssertEqual(local.days[eastern.startOfDay(for: date)]?.words, 5)
        XCTAssertNil(local.days[utc.startOfDay(for: date)])
        XCTAssertNotEqual(HistorySummaryRequest(revision: 1, now: date, calendar: utc),
                          HistorySummaryRequest(revision: 1, now: date, calendar: eastern))
    }
}
