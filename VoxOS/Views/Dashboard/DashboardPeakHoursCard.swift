import SwiftUI

struct DashboardPeakHoursCard: View {
    let summary: DashboardPeakHoursSummary
    var isLocked = false

    private var maxHourlyWords: Int {
        max(summary.hourlyActivity.map(\.wordCount).max() ?? 0, 1)
    }

    private var canShowPattern: Bool {
        !isLocked && summary.hasData
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 16) {
                header

                DashboardPeakHoursHistogram(
                    points: summary.hourlyActivity,
                    maxWords: maxHourlyWords,
                    peakStartHour: summary.startHour,
                    hasData: canShowPattern
                )
            }
            .blur(radius: isLocked ? 2 : 0)
            .opacity(isLocked ? 0.42 : 1)

            if isLocked {
                lockedOverlay
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(DashboardLayout.cardPadding)
        .frame(maxWidth: .infinity, minHeight: 196, maxHeight: 196, alignment: .topLeading)
        .background(DashboardInsightCardBackground())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Peak dictation hours")
        .accessibilityValue(accessibilityValue)
    }

    private var header: some View {
        DashboardSectionLabel(title: "Peak hours") {
            Text(canShowPattern ? windowText : "–")
                .font(.app(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
    }

    private var windowText: String {
        DashboardHourLabel.range(from: summary.startHour, to: summary.endHour)
    }

    private var accessibilityValue: String {
        if isLocked {
            return String(localized: "Continue using VoxOS to unlock peak hours.")
        }

        guard summary.hasData else {
            return String(localized: "No hourly pattern yet.")
        }

        return windowText
    }

    private var lockedOverlay: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.fill")
                .font(.app(size: 14, weight: .bold))
                .foregroundStyle(AppTheme.Text.secondary)
                .frame(width: 34, height: 34)
                .background(AppTheme.Surface.control)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            Text("Continue using VoxOS to unlock peak hours.")
                .font(.app(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: 260)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

}

/// Hour-of-day labels through the locale's own "j" skeleton, so 24-hour locales never see a
/// hardcoded "AM"/"PM".
///
/// The label is a clock hour, not a moment, so it is formatted in GMT from a fixed reference
/// day. Building today's date in the current zone gave a skipped hour on a DST change day ("2 AM"
/// showed as "3 AM" twice), and the static formatter kept whichever zone it was created in.
enum DashboardHourLabel {
    private static let formatter: DateFormatter = {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        return Formatters.localizedHourFormatter(calendar: calendar)
    }()

    static func string(for hour: Int) -> String {
        let hour = ((hour % 24) + 24) % 24
        // The reference date is midnight GMT, so this is exactly `hour` o'clock in the formatter's zone.
        return formatter.string(from: Date(timeIntervalSinceReferenceDate: TimeInterval(hour) * 3600))
    }

    static func range(from startHour: Int, to endHour: Int) -> String {
        String(format: String(localized: "%@ to %@"), string(for: startHour), string(for: endHour))
    }
}

private struct DashboardPeakHoursHistogram: View {
    // Neutral bars on purpose: on the Insights page the productivity line carries the accent.
    private let peakTint = AppTheme.Text.primary
    private let peakTintSoft = AppTheme.Text.secondary

    let points: [DashboardHourlyActivityPoint]
    let maxWords: Int
    let peakStartHour: Int
    let hasData: Bool

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    baseline
                        .frame(width: geometry.size.width)
                        .position(x: geometry.size.width / 2, y: geometry.size.height - 1)

                    HStack(alignment: .bottom, spacing: 4) {
                        ForEach(points) { point in
                            ZStack(alignment: .bottom) {
                                Capsule(style: .continuous)
                                    .fill(AppTheme.Border.subtle.opacity(hasData ? 0.13 : 0.08))
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                                Capsule(style: .continuous)
                                    .fill(barStyle(for: point))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: barHeight(for: point, in: geometry.size))
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .frame(height: 104)

            HStack {
                axisLabel(DashboardHourLabel.string(for: 0))
                Spacer(minLength: 0)
                axisLabel(DashboardHourLabel.string(for: 6))
                Spacer(minLength: 0)
                axisLabel(DashboardHourLabel.string(for: 12))
                Spacer(minLength: 0)
                axisLabel(DashboardHourLabel.string(for: 18))
                Spacer(minLength: 0)
                axisLabel(DashboardHourLabel.string(for: 0))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hourly dictation activity")
    }

    private var baseline: some View {
        Rectangle()
            .fill(AppTheme.Border.subtle.opacity(0.55))
            .frame(height: 1)
    }

    private func barStyle(for point: DashboardHourlyActivityPoint) -> AnyShapeStyle {
        let opacity = barOpacity(for: point)

        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    peakTintSoft.opacity(opacity),
                    peakTint.opacity(opacity * 0.94),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func barHeight(for point: DashboardHourlyActivityPoint, in size: CGSize) -> CGFloat {
        guard hasData, maxWords > 0, point.wordCount > 0 else {
            return 3
        }

        let availableHeight = max(size.height - 10, 1)
        return max(4, availableHeight * (0.40 + (emphasizedActivity(for: point) * 0.60)))
    }

    private func axisLabel(_ label: String) -> some View {
        Text(verbatim: label)
            .font(.app(size: 10, weight: .semibold))
            .foregroundStyle(AppTheme.Text.secondary)
            .lineLimit(1)
    }

    private func isPeakHour(_ hour: Int) -> Bool {
        let hour = normalizedHour(hour)
        let firstHour = normalizedHour(peakStartHour)
        let secondHour = normalizedHour(firstHour + 1)
        return hour == firstHour || hour == secondHour
    }

    private func barOpacity(for point: DashboardHourlyActivityPoint) -> CGFloat {
        guard hasData else {
            return 0.10
        }

        guard point.wordCount > 0, maxWords > 0 else {
            return 0.10
        }

        let normalized = emphasizedActivity(for: point)
        let peakBoost: CGFloat = isPeakHour(point.hour) ? 0.16 : 0

        return min(0.92, 0.22 + (normalized * 0.50) + peakBoost)
    }

    private func emphasizedActivity(for point: DashboardHourlyActivityPoint) -> CGFloat {
        CGFloat(pow(Double(relativeActivity(for: point)), 0.82))
    }

    private func relativeActivity(for point: DashboardHourlyActivityPoint) -> CGFloat {
        let wordScore = relativeScore(
            value: CGFloat(point.wordCount),
            values: points.map { CGFloat($0.wordCount) }
        )

        let activeDayScore = relativeScore(
            value: CGFloat(point.activeDayCount),
            values: points.map { CGFloat($0.activeDayCount) }
        )
        let audioDurationScore = relativeScore(
            value: CGFloat(point.audioDuration),
            values: points.map { CGFloat($0.audioDuration) }
        )

        return (wordScore * 0.64) + (activeDayScore * 0.20) + (audioDurationScore * 0.16)
    }

    private func relativeScore(value: CGFloat, values: [CGFloat]) -> CGFloat {
        let activeValues = values.filter { $0 > 0 }
        guard
            value > 0,
            let minValue = activeValues.min(),
            let maxValue = activeValues.max()
        else {
            return 0
        }

        guard maxValue > minValue else {
            return 0.5
        }

        return min(max((value - minValue) / (maxValue - minValue), 0), 1)
    }

    private func normalizedHour(_ hour: Int) -> Int {
        ((hour % 24) + 24) % 24
    }
}
