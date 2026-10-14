import SwiftUI

/// Where the Dashboard's stats are, decided by `DashboardContent` from the loaded snapshot.
enum DashboardStatsState: Equatable {
    case loading
    /// Stats failed to load and nothing is cached; the hero offers a retry.
    case failed
    /// Nothing dictated yet. Carries the recording shortcut so the copy can name the key.
    case empty(shortcut: String?)
    case loaded

    var isLoaded: Bool { self == .loaded }
}

/// The page's hero: words dictated over the chosen range, how that compares with the period
/// before, and a wide words-per-day line under it.
struct DashboardWordsCard: View {
    let state: DashboardStatsState
    @Binding var range: DashboardRange
    let days: [DashboardDailyActivity]
    let totals: DashboardMetricTotals
    let previousTotals: DashboardMetricTotals?
    let isRetrying: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                DashboardSectionLabel("Words dictated")

                Picker("Range", selection: $range) {
                    ForEach(DashboardRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .disabled(!state.isLoaded)
                .help("Choose the period the Dashboard covers")
            }

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(verbatim: figure)
                    .font(.appDisplay(size: 44, weight: .regular))
                    .foregroundStyle(state.isLoaded ? AppTheme.Text.primary : AppTheme.Text.muted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())

                if state.isLoaded {
                    DashboardDeltaView(
                        delta: DashboardDelta(
                            current: Double(totals.words), previous: previousTotals.map { Double($0.words) }),
                        style: .pill
                    )
                    // The pill sits just above the figure's baseline rather than on its own text baseline.
                    .alignmentGuide(.firstTextBaseline) { dimensions in dimensions[.bottom] + 3 }
                }
            }
            .padding(.top, 8)

            caption
                .padding(.top, 4)

            DashboardWordsChart(days: days, isPlaceholder: !state.isLoaded)
                .padding(.top, 20)
        }
        .dashboardCard()
        .animation(.easeOut(duration: 0.2), value: state)
    }

    private var figure: String {
        state.isLoaded ? Formatters.formattedNumber(totals.words) : "–"
    }

    @ViewBuilder
    private var caption: some View {
        switch state {
        case .loading:
            captionText(String(localized: "Adding up your dictation…"))
        case .failed:
            HStack(spacing: 10) {
                captionText(String(localized: "Your stats couldn’t be loaded. Your dictations are safe."))
                Button("Try again", action: onRetry)
                    .controlSize(.small)
                    .disabled(isRetrying)
            }
        case .empty(let shortcut):
            captionText(
                shortcut.map { String(localized: "Dictate with \($0) to see your first stats.") }
                    ?? String(localized: "Set a recording shortcut in Settings, then dictate to see your first stats.")
            )
        case .loaded:
            captionText(loadedCaption)
        }
    }

    private var loadedCaption: String {
        guard totals.count > 0 else {
            return String(localized: "Nothing dictated in this period.")
        }
        let sessions = Formatters.formattedNumber(totals.count)
        return totals.count == 1
            ? String(localized: "In 1 dictation")
            : String(localized: "In \(sessions) dictations")
    }

    private func captionText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.app(size: 12, weight: .regular))
            .foregroundStyle(AppTheme.Text.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Delta

/// The change from one period to the next, as a fraction of the earlier one.
struct DashboardDelta: Equatable {
    let fraction: Double

    /// Nil when there is no earlier period, or it was zero, so there is nothing honest to compare.
    init?(current: Double, previous: Double?) {
        guard let previous, previous > 0 else { return nil }
        fraction = (current - previous) / previous
    }

    var percentText: String {
        let percent = Int((abs(fraction) * 100).rounded())
        return percent >= 1000 ? "999+%" : "\(percent)%"
    }

    /// Under one percent either way reads as no change.
    var isFlat: Bool { abs(fraction) < 0.01 }

    var color: Color {
        if isFlat { return AppTheme.Text.secondary }
        return fraction > 0 ? AppTheme.Status.success : AppTheme.Status.error
    }

    var symbol: String {
        if isFlat { return "arrow.right" }
        return fraction > 0 ? "arrow.up.right" : "arrow.down.right"
    }
}

/// "↗ 24% vs previous period": a tinted pill in the hero, a plain line in the stat tiles.
struct DashboardDeltaView: View {
    enum Style {
        case pill
        case inline
    }

    let delta: DashboardDelta?
    let style: Style

    var body: some View {
        if let delta {
            label(for: delta)
        } else {
            Text("No earlier period to compare")
                .font(.app(size: 11, weight: .regular))
                .foregroundStyle(AppTheme.Text.muted)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func label(for delta: DashboardDelta) -> some View {
        let content = HStack(spacing: 4) {
            Image(systemName: delta.symbol)
                .font(.app(size: 10, weight: .bold))
            Text(verbatim: delta.percentText)
                .font(.appMono(size: 11, weight: .semibold))
            Text(style == .pill ? LocalizedStringKey("vs previous period") : LocalizedStringKey("vs previous"))
                .font(.app(size: 11, weight: .regular))
                .foregroundStyle(style == .pill ? delta.color.opacity(0.85) : AppTheme.Text.secondary)
        }
        .foregroundStyle(delta.color)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(for: delta))

        switch style {
        case .pill:
            content
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(delta.color.opacity(0.14)))
        case .inline:
            content
        }
    }

    private func accessibilityText(for delta: DashboardDelta) -> String {
        if delta.isFlat {
            return String(localized: "About the same as the previous period")
        }
        return delta.fraction > 0
            ? String(localized: "Up \(delta.percentText) on the previous period")
            : String(localized: "Down \(delta.percentText) on the previous period")
    }
}

// MARK: - Chart

/// Words per day as one thin accent line over a soft fill, with a few mono date labels and a
/// hover read-out of the day under the pointer.
struct DashboardWordsChart: View {
    private static let horizontalInset: CGFloat = 4
    private static let topInset: CGFloat = 12
    private static let bottomInset: CGFloat = 2
    private static let tooltipHalfWidth: CGFloat = 86

    let days: [DashboardDailyActivity]
    let isPlaceholder: Bool

    @State private var hoverIndex: Int?

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                let size = geometry.size
                let points = chartPoints(in: size)

                ZStack(alignment: .topLeading) {
                    gridLines(in: size)

                    if isPlaceholder || !hasWords {
                        baseline(in: size)
                    } else {
                        Self.areaPath(points, bottom: size.height)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        AppTheme.Accent.primary.opacity(0.20), AppTheme.Accent.primary.opacity(0),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )

                        Self.smoothPath(points)
                            .stroke(
                                AppTheme.Accent.primary,
                                style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
                            )
                    }

                    if !isPlaceholder, let hoverIndex, points.indices.contains(hoverIndex) {
                        hoverMarker(at: points[hoverIndex], day: days[hoverIndex], size: size)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        hoverIndex = index(nearest: location.x, width: size.width)
                    case .ended:
                        hoverIndex = nil
                    }
                }
            }
            .frame(height: DashboardLayout.heroChartHeight)

            axisLabels
                .frame(height: 14)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Words per day")
        .accessibilityValue(accessibilitySummary)
    }

    private var hasWords: Bool {
        days.contains { $0.words > 0 }
    }

    private var maxWords: Double {
        Double(max(days.map(\.words).max() ?? 0, 1)) * 1.08
    }

    private func chartPoints(in size: CGSize) -> [CGPoint] {
        guard !days.isEmpty else { return [] }
        let plotWidth = max(size.width - Self.horizontalInset * 2, 1)
        let plotHeight = max(size.height - Self.topInset - Self.bottomInset, 1)
        let step = days.count > 1 ? plotWidth / CGFloat(days.count - 1) : 0

        return days.enumerated().map { index, day in
            let ratio = CGFloat(Double(day.words) / maxWords)
            return CGPoint(
                x: Self.horizontalInset + CGFloat(index) * step,
                y: Self.topInset + plotHeight * (1 - ratio)
            )
        }
    }

    private func index(nearest x: CGFloat, width: CGFloat) -> Int? {
        guard !days.isEmpty else { return nil }
        guard days.count > 1 else { return 0 }
        let plotWidth = max(width - Self.horizontalInset * 2, 1)
        let position = (x - Self.horizontalInset) / plotWidth * CGFloat(days.count - 1)
        return min(max(Int(position.rounded()), 0), days.count - 1)
    }

    private func gridLines(in size: CGSize) -> some View {
        Path { path in
            for fraction in [0.0, 0.5] as [CGFloat] {
                let y = Self.topInset + (size.height - Self.topInset - Self.bottomInset) * fraction
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
        .stroke(AppTheme.Border.subtle, style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
    }

    private func baseline(in size: CGSize) -> some View {
        Path { path in
            let y = size.height - Self.bottomInset
            path.move(to: CGPoint(x: Self.horizontalInset, y: y))
            path.addLine(to: CGPoint(x: size.width - Self.horizontalInset, y: y))
        }
        .stroke(AppTheme.Border.card, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
    }

    private func hoverMarker(at point: CGPoint, day: DashboardDailyActivity, size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: point.x, y: 0))
                path.addLine(to: CGPoint(x: point.x, y: size.height))
            }
            .stroke(AppTheme.Text.muted, lineWidth: 1)

            Circle()
                .fill(AppTheme.Accent.primary)
                .frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(AppTheme.Surface.window, lineWidth: 2))
                .position(point)

            Text(verbatim: tooltipText(for: day))
                .font(.appMono(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Text.primary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(AppTheme.Surface.window)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(AppTheme.Border.control, lineWidth: 1)
                )
                .position(
                    x: min(
                        max(point.x, Self.tooltipHalfWidth),
                        max(size.width - Self.tooltipHalfWidth, Self.tooltipHalfWidth)),
                    y: point.y > 34 ? point.y - 20 : point.y + 22
                )
        }
        .allowsHitTesting(false)
    }

    private func tooltipText(for day: DashboardDailyActivity) -> String {
        let date = day.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        let words = Formatters.formattedNumber(day.words)
        return day.words == 1
            ? String(localized: "\(date) · 1 word")
            : String(localized: "\(date) · \(words) words")
    }

    /// A handful of dates under the line: every day for a week, about weekly for a month.
    private var axisLabels: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let plotWidth = max(width - Self.horizontalInset * 2, 1)
            let indices = labelIndices
            let lastIndex = max(days.count - 1, 1)

            ZStack(alignment: .topLeading) {
                ForEach(indices, id: \.self) { index in
                    let x = Self.horizontalInset + plotWidth * CGFloat(index) / CGFloat(lastIndex)
                    let anchor: CGFloat = index == 0 ? 0 : (index == days.count - 1 ? 1 : 0.5)

                    Text(verbatim: axisLabel(for: index))
                        .font(.appMono(size: 10, weight: .regular))
                        .foregroundStyle(AppTheme.Text.muted)
                        .lineLimit(1)
                        .fixedSize()
                        .alignmentGuide(.leading) { dimensions in dimensions.width * anchor - x }
                }
            }
            .frame(width: width, alignment: .topLeading)
        }
        .accessibilityHidden(true)
    }

    private var labelIndices: [Int] {
        let count = days.count
        guard count > 1 else { return count == 1 ? [0] : [] }
        if count <= 7 { return Array(0..<count) }
        let step = Double(count - 1) / 4
        return (0...4).map { Int((Double($0) * step).rounded()) }
    }

    private func axisLabel(for index: Int) -> String {
        guard days.indices.contains(index) else { return "" }
        if index == days.count - 1 { return String(localized: "Today") }
        let date = days[index].date
        return days.count <= 7
            ? date.formatted(.dateTime.weekday(.abbreviated))
            : date.formatted(.dateTime.day().month(.abbreviated))
    }

    private var accessibilitySummary: String {
        guard !isPlaceholder, let busiest = days.max(by: { $0.words < $1.words }), busiest.words > 0 else {
            return String(localized: "No words yet")
        }
        let date = busiest.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        return String(localized: "Most words on \(date): \(Formatters.formattedNumber(busiest.words))")
    }

    // MARK: Paths

    private static func areaPath(_ points: [CGPoint], bottom: CGFloat) -> Path {
        guard let first = points.first, let last = points.last else { return Path() }
        var path = smoothPath(points)
        path.addLine(to: CGPoint(x: last.x, y: bottom))
        path.addLine(to: CGPoint(x: first.x, y: bottom))
        path.closeSubpath()
        return path
    }

    /// A monotone cubic through the points, so the curve never overshoots a day's value and
    /// never dips below the baseline between two quiet days.
    static func smoothPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            points.dropFirst().forEach { path.addLine(to: $0) }
            return path
        }

        let count = points.count
        var secants = [CGFloat](repeating: 0, count: count - 1)
        for index in 0..<(count - 1) {
            let dx = points[index + 1].x - points[index].x
            secants[index] = dx == 0 ? 0 : (points[index + 1].y - points[index].y) / dx
        }

        var tangents = [CGFloat](repeating: 0, count: count)
        tangents[0] = secants[0]
        tangents[count - 1] = secants[count - 2]
        for index in 1..<(count - 1) {
            let before = secants[index - 1]
            let after = secants[index]
            tangents[index] = before * after <= 0 ? 0 : (before + after) / 2
        }

        for index in 0..<(count - 1) where secants[index] != 0 {
            let alpha = tangents[index] / secants[index]
            let beta = tangents[index + 1] / secants[index]
            let magnitude = alpha * alpha + beta * beta
            if magnitude > 9 {
                let scale = 3 / magnitude.squareRoot()
                tangents[index] = scale * alpha * secants[index]
                tangents[index + 1] = scale * beta * secants[index]
            }
        }
        for index in 0..<(count - 1) where secants[index] == 0 {
            tangents[index] = 0
            tangents[index + 1] = 0
        }

        for index in 0..<(count - 1) {
            let start = points[index]
            let end = points[index + 1]
            let third = (end.x - start.x) / 3
            path.addCurve(
                to: end,
                control1: CGPoint(x: start.x + third, y: start.y + tangents[index] * third),
                control2: CGPoint(x: end.x - third, y: end.y - tangents[index + 1] * third)
            )
        }
        return path
    }
}
