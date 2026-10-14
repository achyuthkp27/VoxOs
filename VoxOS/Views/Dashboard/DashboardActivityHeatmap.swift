import SwiftUI

/// The last five weeks as a calendar: a column per week, a row per weekday, each day a rounded
/// square in the accent at a strength set by its words. Today is outlined; days still to come
/// are left empty. Beside it: the busiest time, active days and the current streak.
struct DashboardActivityHeatmap: View {
    private static let weekCount = 5
    private static let cellSize: CGFloat = 20
    private static let cellSpacing: CGFloat = 5
    private static let levelOpacities: [Double] = [0.24, 0.44, 0.68, 0.95]

    let days: [DashboardDailyActivity]
    let peakHours: DashboardPeakHoursSummary
    let isLoaded: Bool

    private struct Cell: Identifiable {
        var id: Date { date }
        let date: Date
        let words: Int
        let count: Int
        let isToday: Bool
        let isFuture: Bool
    }

    private let calendar = DashboardPeriodWindows.dashboardCalendar()

    var body: some View {
        let cells = makeCells()

        VStack(alignment: .leading, spacing: 0) {
            DashboardSectionLabel(title: "Activity") {
                Text("Last 5 weeks")
                    .font(.app(size: 11, weight: .regular))
                    .foregroundStyle(AppTheme.Text.muted)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 28) {
                    grid(cells)
                    summary(cells)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 16) {
                    grid(cells)
                    summary(cells)
                }
            }
            .padding(.top, 16)
        }
        .dashboardCard(fillsHeight: true)
    }

    // MARK: Grid

    private func grid(_ cells: [Cell]) -> some View {
        let maxWords = max(cells.map(\.words).max() ?? 0, 1)

        return HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .trailing, spacing: Self.cellSpacing) {
                ForEach(0..<7, id: \.self) { row in
                    Text(verbatim: weekdaySymbol(forRow: row))
                        .font(.appMono(size: 10, weight: .regular))
                        .foregroundStyle(AppTheme.Text.muted)
                        .frame(height: Self.cellSize)
                }
            }

            HStack(alignment: .top, spacing: Self.cellSpacing) {
                ForEach(0..<Self.weekCount, id: \.self) { column in
                    VStack(spacing: Self.cellSpacing) {
                        ForEach(0..<7, id: \.self) { row in
                            let index = column * 7 + row
                            if cells.indices.contains(index) {
                                cellView(cells[index], maxWords: maxWords)
                            }
                        }
                    }
                }
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Activity, last 5 weeks")
        .accessibilityValue(activeDaysText(cells))
    }

    private func cellView(_ cell: Cell, maxWords: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)

        return
            shape
            .fill(fill(for: cell, maxWords: maxWords))
            .overlay {
                if cell.isToday {
                    shape.strokeBorder(AppTheme.Text.primary.opacity(0.85), lineWidth: 1.5)
                } else if cell.isFuture {
                    shape.strokeBorder(AppTheme.Border.subtle, lineWidth: 1)
                }
            }
            .frame(width: Self.cellSize, height: Self.cellSize)
            .help(Text(verbatim: tooltip(for: cell)))
    }

    private func fill(for cell: Cell, maxWords: Int) -> Color {
        guard isLoaded, !cell.isFuture else { return .clear }
        guard cell.words > 0 || cell.count > 0 else { return AppTheme.Surface.control }

        // Square root so a few heavy days do not wash every other day out to the lowest step.
        let ratio = (Double(cell.words) / Double(maxWords)).squareRoot()
        let level = min(
            max(Int((ratio * Double(Self.levelOpacities.count)).rounded(.up)), 1), Self.levelOpacities.count)
        return AppTheme.Accent.primary.opacity(Self.levelOpacities[level - 1])
    }

    private func tooltip(for cell: Cell) -> String {
        let date = cell.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        guard !cell.isFuture else { return date }
        guard cell.count > 0 else { return String(localized: "\(date): no dictation") }
        let words = Formatters.formattedNumber(cell.words)
        let dictations = Formatters.formattedNumber(cell.count)
        return cell.count == 1
            ? String(localized: "\(date): \(words) words in 1 dictation")
            : String(localized: "\(date): \(words) words in \(dictations) dictations")
    }

    // MARK: Summary

    private func summary(_ cells: [Cell]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let busiest = busiestText(cells) {
                fact(label: "Busiest", value: busiest)
            }

            fact(label: "Active days", value: isLoaded ? activeDaysText(cells) : "–")

            fact(label: "Streak", value: isLoaded ? streakText(cells) : "–")

            legend
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func fact(label: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.appMono(size: 10, weight: .medium))
                .foregroundStyle(AppTheme.Text.muted)
                .textCase(.uppercase)
                .tracking(0.6)
            Text(verbatim: value)
                .font(.app(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.Text.primary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Text("Less")
                .font(.appMono(size: 10, weight: .regular))
                .foregroundStyle(AppTheme.Text.muted)
                .padding(.trailing, 2)

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(AppTheme.Surface.control)
                .frame(width: 10, height: 10)

            ForEach(Self.levelOpacities, id: \.self) { opacity in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(AppTheme.Accent.primary.opacity(opacity))
                    .frame(width: 10, height: 10)
            }

            Text("More")
                .font(.appMono(size: 10, weight: .regular))
                .foregroundStyle(AppTheme.Text.muted)
                .padding(.leading, 2)
        }
        .accessibilityHidden(true)
    }

    /// "Tue · 10 AM to 12 PM": the weekday with the most words in the grid, and the two-hour
    /// window with the most words over the range.
    private func busiestText(_ cells: [Cell]) -> String? {
        guard isLoaded else { return nil }

        var wordsByRow = [Int](repeating: 0, count: 7)
        for (index, cell) in cells.enumerated() where !cell.isFuture {
            wordsByRow[index % 7] += cell.words
        }

        let weekday: String? = {
            guard let best = wordsByRow.indices.max(by: { wordsByRow[$0] < wordsByRow[$1] }),
                wordsByRow[best] > 0
            else { return nil }
            return weekdaySymbol(forRow: best)
        }()
        let hours = peakHours.hasData ? DashboardHourLabel.range(from: peakHours.startHour, to: peakHours.endHour) : nil

        switch (weekday, hours) {
        case (let weekday?, let hours?): return "\(weekday) · \(hours)"
        case (let weekday?, nil): return weekday
        case (nil, let hours?): return hours
        case (nil, nil): return nil
        }
    }

    private func activeDaysText(_ cells: [Cell]) -> String {
        let elapsed = cells.filter { !$0.isFuture }
        let active = elapsed.filter { $0.count > 0 }.count
        return String(localized: "\(active) of \(elapsed.count)")
    }

    /// Consecutive days with a dictation, ending today (or yesterday, so a streak is not shown as
    /// broken before today's first dictation).
    private func streakText(_ cells: [Cell]) -> String {
        var activeDays = Set(days.filter { $0.count > 0 }.map(\.date))
        cells.filter { $0.count > 0 }.forEach { activeDays.insert($0.date) }

        let today = calendar.startOfDay(for: Date())
        var cursor = activeDays.contains(today) ? today : (calendar.date(byAdding: .day, value: -1, to: today) ?? today)
        var streak = 0
        while activeDays.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }

        return streak == 1 ? String(localized: "1 day") : String(localized: "\(streak) days")
    }

    // MARK: Data

    /// Five whole weeks ending with the current one, column by column, in the dashboard
    /// calendar's week order.
    private func makeCells() -> [Cell] {
        let today = calendar.startOfDay(for: Date())
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        guard let gridStart = calendar.date(byAdding: .day, value: -7 * (Self.weekCount - 1), to: weekStart) else {
            return []
        }

        let byDay = Dictionary(
            days.map { (calendar.startOfDay(for: $0.date), $0) }, uniquingKeysWith: { first, _ in first })

        return (0..<(Self.weekCount * 7)).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: gridStart) else { return nil }
            let day = byDay[date]
            return Cell(
                date: date,
                words: day?.words ?? 0,
                count: day?.count ?? 0,
                isToday: date == today,
                isFuture: date > today
            )
        }
    }

    private func weekdaySymbol(forRow row: Int) -> String {
        let symbols = calendar.shortWeekdaySymbols
        guard symbols.count == 7 else { return "" }
        return symbols[(calendar.firstWeekday - 1 + row) % 7]
    }
}
