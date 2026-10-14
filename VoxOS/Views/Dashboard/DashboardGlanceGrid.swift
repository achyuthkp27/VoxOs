import SwiftUI

/// Four equal cards under the hero: today, speaking pace, busiest time and all time. Each is a
/// label, one figure and one line of context, so the row reads at a glance.
struct DashboardGlanceGrid: View {
    let today: DashboardMetricTotals
    let allTime: DashboardMetricTotals
    let peakHours: DashboardPeakHoursSummary
    let isLoaded: Bool
    let columnCount: Int

    private enum Card: CaseIterable, Hashable {
        case today, pace, busiestTime, allTime
    }

    private var rows: [[Card]] {
        let cards = Card.allCases
        let columns = max(columnCount, 1)
        return stride(from: 0, to: cards.count, by: columns).map { start in
            Array(cards[start..<min(start + columns, cards.count)])
        }
    }

    var body: some View {
        Grid(horizontalSpacing: DashboardLayout.columnSpacing, verticalSpacing: DashboardLayout.columnSpacing) {
            ForEach(rows, id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { card in
                        view(for: card)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func view(for card: Card) -> some View {
        switch card {
        case .today:
            DashboardGlanceCard(title: "Today", value: todayValue, detail: todayDetail)
        case .pace:
            DashboardGlanceCard(
                title: "Speaking pace",
                value: paceValue,
                detail: paceDetail,
                info: "Time saved compares how long you spoke with typing the same words at 40 words a minute."
            )
        case .busiestTime:
            DashboardGlanceCard(title: "Busiest time", value: busiestValue, detail: busiestDetail) {
                if peakHours.hasData {
                    DashboardHourStrip(summary: peakHours)
                }
            }
        case .allTime:
            DashboardGlanceCard(title: "All time", value: allTimeValue, detail: allTimeDetail)
        }
    }

    // MARK: - Today

    private var todayValue: String {
        guard isLoaded else { return "–" }
        guard today.words > 0 else { return String(localized: "No words yet") }
        return Self.wordsText(today.words)
    }

    private var todayDetail: String? {
        guard isLoaded else { return nil }
        guard today.count > 0 else { return String(localized: "Hold your shortcut in any text field to begin.") }

        let sessions = Self.sessionsText(today.count)
        let saved = DashboardTimeSaving.timeSaved(words: today.words, duration: today.duration)
        guard saved >= 60 else { return sessions }
        return String(localized: "\(sessions) · \(Formatters.formattedSavedTime(saved)) saved")
    }

    // MARK: - Pace

    /// Under half a minute of audio the rate swings too much to be worth showing.
    private var hasPace: Bool {
        isLoaded && allTime.words > 0 && allTime.duration >= 30
    }

    private var paceValue: String {
        guard hasPace else { return "–" }
        let wordsPerMinute = Int((Double(allTime.words) / (allTime.duration / 60)).rounded())
        return String(localized: "\(Formatters.formattedNumber(wordsPerMinute)) wpm")
    }

    private var paceDetail: String {
        guard hasPace else { return String(localized: "Shows up after your first few dictations.") }

        let speedup = DashboardTimeSaving.estimatedTypingTime(words: allTime.words) / allTime.duration
        guard speedup >= 1.15 else { return String(localized: "About as fast as typing so far.") }

        let multiple = speedup.formatted(.number.precision(.fractionLength(speedup < 10 ? 1 : 0)))
        return String(localized: "About \(multiple)× faster than typing.")
    }

    // MARK: - Busiest time

    private var busiestValue: String {
        guard isLoaded, peakHours.hasData else { return "–" }
        return DashboardHourLabel.range(from: peakHours.startHour, to: peakHours.endHour)
    }

    private var busiestDetail: String? {
        guard isLoaded, peakHours.hasData else {
            return String(localized: "Your daily rhythm shows up after a few dictations.")
        }
        return nil
    }

    // MARK: - All time

    private var allTimeValue: String {
        guard isLoaded, allTime.words > 0 else { return "–" }
        return Self.wordsText(allTime.words, compact: true)
    }

    private var allTimeDetail: String {
        guard isLoaded, allTime.words > 0 else { return String(localized: "Every word you dictate counts here.") }

        switch DashboardProgressBenchmark.equivalence(for: allTime.words) {
        case .matched(let title):
            return String(localized: "As long as \(title).")
        case .repeated(let title, let count):
            return String(localized: "\(title), \(Formatters.formattedNumber(count)) times over.")
        case .remaining(let words, let title):
            guard words > 0, !title.isEmpty else { return Self.sessionsText(allTime.count) }
            return String(localized: "\(Formatters.formattedNumber(words)) words to go to \(title).")
        }
    }

    // MARK: - Text

    private static func wordsText(_ words: Int, compact: Bool = false) -> String {
        let count = compact ? Formatters.formattedCompactNumber(words) : Formatters.formattedNumber(words)
        return words == 1 ? String(localized: "\(count) word") : String(localized: "\(count) words")
    }

    private static func sessionsText(_ sessions: Int) -> String {
        sessions == 1
            ? String(localized: "1 session")
            : String(localized: "\(Formatters.formattedNumber(sessions)) sessions")
    }
}

private struct DashboardGlanceCard<Accessory: View>: View {
    let title: LocalizedStringKey
    let value: String
    let detail: String?
    var info: LocalizedStringKey?
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardSectionLabel(title: title) {
                if let info {
                    InfoTip(info)
                        .font(.app(size: 11))
                        .opacity(0.6)
                        .padding(-5)
                }
            }

            Text(value)
                .font(.app(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(AppTheme.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 12)
                .contentTransition(.numericText())

            if let detail {
                Text(detail)
                    .font(.app(size: 12, weight: .regular))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }

            Spacer(minLength: 12)

            accessory()
        }
        .frame(maxWidth: .infinity, minHeight: 104, maxHeight: .infinity, alignment: .topLeading)
        .dashboardCard()
        .accessibilityElement(children: .combine)
    }
}

extension DashboardGlanceCard where Accessory == EmptyView {
    init(title: LocalizedStringKey, value: String, detail: String?, info: LocalizedStringKey? = nil) {
        self.title = title
        self.value = value
        self.detail = detail
        self.info = info
        self.accessory = { EmptyView() }
    }
}

/// The 24 hours as hairline ticks, the busiest two drawn in full text colour. Deliberately
/// colourless so the hero waveform stays the only accent on the page.
private struct DashboardHourStrip: View {
    let summary: DashboardPeakHoursSummary

    private var maxWords: Int {
        max(summary.hourlyActivity.map(\.wordCount).max() ?? 0, 1)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(summary.hourlyActivity) { point in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(isPeak(point.hour) ? AppTheme.Text.primary : AppTheme.Text.muted.opacity(0.55))
                    .frame(maxWidth: .infinity)
                    .frame(height: height(for: point))
            }
        }
        .frame(height: 22, alignment: .bottom)
        .accessibilityHidden(true)
    }

    private func height(for point: DashboardHourlyActivityPoint) -> CGFloat {
        guard point.wordCount > 0 else { return 2 }
        return max(4, 22 * CGFloat(Double(point.wordCount) / Double(maxWords)).squareRoot())
    }

    private func isPeak(_ hour: Int) -> Bool {
        let start = ((summary.startHour % 24) + 24) % 24
        return hour == start || hour == (start + 1) % 24
    }
}
