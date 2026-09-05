//
//  StatisticsView.swift
//  speaktype
//
//  Created on 2026-01-19.
//  Statistics view showing daily word transcription trends
//

import Charts
import SwiftUI

struct StatisticsView: View {
    @StateObject private var historyService = HistoryService.shared
    @ObservedObject private var audioRecorder = AudioRecordingService.shared
    @State private var selectedPeriod: StatisticsPeriod = .week
    @State private var timer: Timer? = nil
    @State private var timeTrigger = Date()
    @State private var summary = HistoryPeriodSummary()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                summaryCards
                barChartSection
                detailsSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .background(Color.clear)
        .task(id: HistorySummaryRequest(revision: historyService.revision, now: timeTrigger, period: selectedPeriod.rawValue)) {
            let entries = historyService.statsEntries
            let period = selectedPeriod
            let now = timeTrigger
            let calendar = Calendar.current
            let result = await Task.detached(priority: .userInitiated) {
                HistoryStatisticsSummary.build(entries, calendar: calendar)
                    .period(period, now: now, calendar: calendar)
            }.value
            guard !Task.isCancelled else { return }
            summary = result
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in timeTrigger = Date() }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name.NSSystemTimeZoneDidChange)) { _ in timeTrigger = Date() }
        .onAppear {
            startTimer()
        }
        .onDisappear {
            stopTimer()
        }
        .onChange(of: audioRecorder.isRecording) {
            if audioRecorder.isRecording {
                startTimer()
            } else {
                stopTimer()
                // Force one last update
                timeTrigger = Date()
            }
        }
    }

    // MARK: - View Components

    private var headerSection: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Statistics")
                    .font(Typography.displayLarge)
                    .foregroundStyle(Color.textPrimary)

                Text(
                    "\(totalWords(for: selectedPeriod)) words this \(selectedPeriod.rawValue.lowercased())"
                )
                .font(Typography.bodySmall)
                .foregroundStyle(Color.textSecondary)
            }

            Spacer()

            // Period selector
            HStack(spacing: 8) {
                ForEach(StatisticsPeriod.allCases) { period in
                    PeriodButton(
                        period: period,
                        isSelected: selectedPeriod == period,
                        action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                selectedPeriod = period
                            }
                        }
                    )
                }
            }
        }
    }

    private var summaryCards: some View {
        HStack(spacing: 16) {
            StatCard(
                icon: "doc.text.fill",
                label: "Total Words",
                value: "\(totalWords(for: selectedPeriod))"
            )

            StatCard(
                icon: "calendar",
                label: "Daily Average",
                value: "\(dailyAverage(for: selectedPeriod))"
            )

            StatCard(
                icon: "chart.line.uptrend.xyaxis",
                label: "Best Day",
                value: "\(bestDay(for: selectedPeriod))"
            )

            StatCard(
                icon: "number",
                label: "Transcriptions",
                value: "\(transcriptionCount(for: selectedPeriod))"
            )
        }
    }

    private var barChartSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("Activity")
                    .font(Typography.headlineLarge)
                    .foregroundStyle(Color.textPrimary)

                Spacer()

                if !dailyData(for: selectedPeriod).isEmpty {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(transcriptionCount(for: selectedPeriod)) transcriptions")
                            .font(Typography.labelSmall)
                            .foregroundStyle(Color.textSecondary)
                        Text(formattedDuration(for: selectedPeriod))
                            .font(Typography.captionSmall)
                            .foregroundStyle(Color.textMuted)
                    }
                }
            }

            if dailyData(for: selectedPeriod).isEmpty {
                emptyChartView
            } else {
                chartView
            }
        }
        .padding(24)
        .background(Color.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.border.opacity(0.5), lineWidth: 1)
        )
        .cardShadow()
    }

    private var emptyChartView: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 48))
                .foregroundStyle(Color.textMuted.opacity(0.4))

            VStack(spacing: 6) {
                Text("No activity yet")
                    .font(Typography.headlineMedium)
                    .foregroundStyle(Color.textPrimary)

                Text("Your transcription statistics will appear here")
                    .font(Typography.bodySmall)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 280)
    }

    private var chartView: some View {
        Chart {
            ForEach(dailyData(for: selectedPeriod)) { data in
                BarMark(
                    x: .value("Date", data.dateString),
                    y: .value("Words", data.wordCount)
                )
                .foregroundStyle(Color.textSecondary.opacity(0.3))
                .cornerRadius(8)
            }
        }
        .chartXAxis {
            if selectedPeriod == .year {
                // For year (monthly view), show months
                AxisMarks(values: .automatic) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.border.opacity(0.2))
                    AxisValueLabel()
                        .font(Typography.captionSmall)
                        .foregroundStyle(Color.textMuted)
                }
            } else if selectedPeriod == .month {
                // For month view, show every 7 days
                AxisMarks(values: .stride(by: .day, count: 7)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.border.opacity(0.2))
                    AxisValueLabel()
                        .font(Typography.captionSmall)
                        .foregroundStyle(Color.textMuted)
                }
            } else {
                // For week view, show all days
                AxisMarks { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Color.border.opacity(0.2))
                    AxisValueLabel()
                        .font(Typography.captionSmall)
                        .foregroundStyle(Color.textMuted)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(Color.border.opacity(0.2))
                AxisValueLabel()
                    .font(Typography.captionSmall)
                    .foregroundStyle(Color.textMuted)
            }
        }
        .chartPlotStyle { plotArea in
            plotArea.background(Color.clear)
        }
        .frame(height: 280)
        .padding(.top, 8)
    }

    private var detailsSection: some View {
        HStack(spacing: 16) {
            DetailCard(
                icon: "number",
                label: "Avg. words per note",
                value: "\(averageWordsPerTranscription(for: selectedPeriod))"
            )

            DetailCard(
                icon: "star.fill",
                label: "Most active day",
                value: mostActiveDay(for: selectedPeriod)
            )

            DetailCard(
                icon: "clock",
                label: "Total duration",
                value: formattedDuration(for: selectedPeriod)
            )
        }
    }

    // MARK: - Data Calculations

    private func dailyData(for period: StatisticsPeriod) -> [DailyWordCount] { summary.data }

    private func totalWords(for period: StatisticsPeriod) -> Int { summary.totals.words }

    private func dailyAverage(for period: StatisticsPeriod) -> Int {
        guard !summary.data.isEmpty else { return 0 }
        return summary.totals.words / summary.data.count
    }

    private func bestDay(for period: StatisticsPeriod) -> Int {
        summary.data.map(\.wordCount).max() ?? 0
    }

    private func transcriptionCount(for period: StatisticsPeriod) -> Int { summary.totals.count }

    private func formattedDuration(for period: StatisticsPeriod) -> String {
        let startDate = summary.start
        var totalSeconds = summary.totals.duration

        // Add current recording duration if active
        if audioRecorder.isRecording, let recordingStart = audioRecorder.recordingStartTime {
            let currentDuration = timeTrigger.timeIntervalSince(recordingStart)
            // Only add if start date falls within period (usually true for 'now')
            if recordingStart >= startDate {
                totalSeconds += currentDuration
            }
        }

        // Formatting Logic
        if totalSeconds < 60 {
            return "\(Int(totalSeconds))s"
        }

        let minutes = Int(totalSeconds) / 60
        let hours = minutes / 60
        let remainingMinutes = minutes % 60

        if hours > 0 {
            return "\(hours)h \(remainingMinutes)m"
        } else {
            return "\(remainingMinutes)m"
        }
    }

    private func startTimer() {
        stopTimer()
        guard audioRecorder.isRecording else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            timeTrigger = Date()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func averageWordsPerTranscription(for period: StatisticsPeriod) -> Int {
        let count = transcriptionCount(for: period)
        guard count > 0 else { return 0 }
        return totalWords(for: period) / count
    }

    private func mostActiveDay(for period: StatisticsPeriod) -> String {
        let data = dailyData(for: period)
        guard let maxData = data.max(by: { $0.wordCount < $1.wordCount }),
            maxData.wordCount > 0
        else {
            return "N/A"
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: maxData.date)
    }
}

// MARK: - Supporting Types

nonisolated enum StatisticsPeriod: String, CaseIterable, Identifiable, Sendable {
    case week = "Week"
    case month = "Month"
    case year = "Year"

    var id: String { rawValue }
}

nonisolated struct DailyWordCount: Identifiable, Sendable {
    var id: Date { date }
    let date: Date
    let wordCount: Int
    let isMonthly: Bool

    var dateString: String {
        let formatter = DateFormatter()
        if isMonthly {
            formatter.dateFormat = "MMM"
        } else {
            formatter.dateFormat = "MMM d"
        }
        return formatter.string(from: date)
    }
}

// MARK: - Supporting Views

struct StatCard: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(Color.textMuted)

            Text(value)
                .font(.system(size: 32, weight: .light, design: .serif))
                .foregroundStyle(Color.textPrimary)

            Text(label)
                .font(Typography.captionSmall)
                .foregroundStyle(Color.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.border.opacity(0.5), lineWidth: 1)
        )
    }
}

struct DetailCard: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Color.textMuted)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(Typography.captionSmall)
                    .foregroundStyle(Color.textSecondary)
                Text(value)
                    .font(Typography.labelMedium)
                    .foregroundStyle(Color.textPrimary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.border.opacity(0.5), lineWidth: 1)
        )
    }
}

struct PeriodButton: View {
    let period: StatisticsPeriod
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(period.rawValue)
                .font(Typography.labelMedium)
                .foregroundStyle(isSelected ? Color.textPrimary : Color.textMuted)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(isSelected ? Color.bgHover : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    StatisticsView()
}
