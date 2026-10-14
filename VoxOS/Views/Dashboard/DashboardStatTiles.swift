import SwiftUI

/// Four equal tiles under the hero, all for the selected range: time saved, dictations,
/// speaking pace and average length. Each is a mono label, one figure, one line of change and,
/// where a daily trend means something, a sparkline from the same series as the hero chart.
struct DashboardStatTiles: View {
    /// Under half a minute of audio the pace swings too much to be worth showing.
    private static let minimumPaceDuration: TimeInterval = 30

    let isLoaded: Bool
    let days: [DashboardDailyActivity]
    let totals: DashboardMetricTotals
    let previousTotals: DashboardMetricTotals?
    let columnCount: Int

    private enum Tile: CaseIterable, Hashable {
        case timeSaved, dictations, pace, averageLength
    }

    private var rows: [[Tile]] {
        let tiles = Tile.allCases
        let columns = max(columnCount, 1)
        return stride(from: 0, to: tiles.count, by: columns).map { start in
            Array(tiles[start..<min(start + columns, tiles.count)])
        }
    }

    var body: some View {
        Grid(horizontalSpacing: DashboardLayout.gridSpacing, verticalSpacing: DashboardLayout.gridSpacing) {
            ForEach(rows, id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { tile in
                        view(for: tile)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func view(for tile: Tile) -> some View {
        switch tile {
        case .timeSaved:
            DashboardStatTile(
                title: "Time saved",
                value: isLoaded ? Formatters.formattedSavedTime(saved(totals)) : "–",
                unit: nil,
                detail: isLoaded
                    ? .delta(DashboardDelta(current: saved(totals), previous: previousTotals.map(saved)))
                    : .placeholder,
                sparkline: isLoaded
                    ? days.map { saved(DashboardMetricTotals(count: $0.count, words: $0.words, duration: $0.duration)) }
                    : nil,
                info: "Compares how long you spoke with typing the same words at 40 words a minute."
            )
        case .dictations:
            DashboardStatTile(
                title: "Dictations",
                value: isLoaded ? Formatters.formattedNumber(totals.count) : "–",
                unit: nil,
                detail: isLoaded
                    ? .delta(
                        DashboardDelta(current: Double(totals.count), previous: previousTotals.map { Double($0.count) })
                    )
                    : .placeholder,
                sparkline: isLoaded ? days.map { Double($0.count) } : nil
            )
        case .pace:
            DashboardStatTile(
                title: "Speaking pace",
                value: pace(totals).map { Formatters.formattedNumber(Int($0.rounded())) } ?? "–",
                unit: pace(totals) == nil ? nil : String(localized: "wpm"),
                detail: paceDetail,
                sparkline: nil
            )
        case .averageLength:
            DashboardStatTile(
                title: "Avg. length",
                value: averageLength(totals).map { Formatters.formattedNumber(Int($0.rounded())) } ?? "–",
                unit: averageLength(totals) == nil ? nil : String(localized: "words"),
                detail: isLoaded
                    ? .delta(
                        averageLength(totals).flatMap { current in
                            DashboardDelta(current: current, previous: previousTotals.flatMap(averageLength))
                        })
                    : .placeholder,
                sparkline: nil
            )
        }
    }

    private func saved(_ totals: DashboardMetricTotals) -> Double {
        DashboardTimeSaving.timeSaved(words: totals.words, duration: totals.duration)
    }

    private func pace(_ totals: DashboardMetricTotals) -> Double? {
        guard isLoaded, totals.words > 0, totals.duration >= Self.minimumPaceDuration else { return nil }
        return Double(totals.words) / (totals.duration / 60)
    }

    private func averageLength(_ totals: DashboardMetricTotals) -> Double? {
        guard isLoaded, totals.count > 0 else { return nil }
        return Double(totals.words) / Double(totals.count)
    }

    private var paceDetail: DashboardStatTile.Detail {
        guard isLoaded else { return .placeholder }
        guard totals.duration >= Self.minimumPaceDuration, totals.words > 0 else {
            return .text(String(localized: "Shows after a few dictations"))
        }

        let speedup = DashboardTimeSaving.estimatedTypingTime(words: totals.words) / totals.duration
        guard speedup >= 1.15 else { return .text(String(localized: "About as fast as typing")) }

        let multiple = speedup.formatted(.number.precision(.fractionLength(speedup < 10 ? 1 : 0)))
        return .text(String(localized: "\(multiple)× faster than typing"))
    }
}

/// One stat: label, figure with an optional unit, a line under it and an optional sparkline.
struct DashboardStatTile: View {
    enum Detail {
        case delta(DashboardDelta?)
        case text(String)
        case placeholder
    }

    let title: LocalizedStringKey
    let value: String
    let unit: String?
    let detail: Detail
    let sparkline: [Double]?
    var info: LocalizedStringKey?

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

            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(verbatim: value)
                            .font(.app(size: 23, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(AppTheme.Text.primary)
                            .contentTransition(.numericText())

                        if let unit {
                            Text(verbatim: unit)
                                .font(.app(size: 12, weight: .medium))
                                .foregroundStyle(AppTheme.Text.secondary)
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                    detailView
                }

                Spacer(minLength: 0)

                if let sparkline {
                    DashboardSparkline(values: sparkline)
                        .frame(width: 60, height: 26)
                        .padding(.bottom, 2)
                }
            }
            .padding(.top, 10)
        }
        .dashboardCard(fillsHeight: true)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var detailView: some View {
        switch detail {
        case .delta(let delta):
            DashboardDeltaView(delta: delta, style: .inline)
        case .text(let text):
            Text(verbatim: text)
                .font(.app(size: 11, weight: .regular))
                .foregroundStyle(AppTheme.Text.secondary)
                .lineLimit(1)
        case .placeholder:
            Text(verbatim: " ")
                .font(.app(size: 11, weight: .regular))
                .accessibilityHidden(true)
        }
    }
}

/// A tiny accent line of a daily series, scaled to its own peak. Flat and muted when the
/// series is all zero, so an empty range does not pretend to have a trend.
struct DashboardSparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geometry in
            let peak = values.max() ?? 0
            let points = values.enumerated().map { index, value in
                CGPoint(
                    x: values.count > 1 ? geometry.size.width * CGFloat(index) / CGFloat(values.count - 1) : 0,
                    y: peak > 0
                        ? 1 + (geometry.size.height - 2) * (1 - CGFloat(value / peak))
                        : geometry.size.height - 1
                )
            }

            DashboardWordsChart.smoothPath(points)
                .stroke(
                    peak > 0 ? AppTheme.Accent.primary : AppTheme.Border.control,
                    style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)
                )
        }
        .accessibilityHidden(true)
    }
}
