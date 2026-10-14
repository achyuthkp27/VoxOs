import SwiftUI

struct DashboardTimeSavedSummary: Equatable {
    let timeSaved: TimeInterval
    let wordCount: Int
    let sessionCount: Int

    var hasData: Bool {
        sessionCount > 0 || wordCount > 0
    }
}

struct DashboardTimeSavedCard: View {
    let summary: DashboardTimeSavedSummary
    let period: DashboardInsightPeriod

    private var savedTimeText: String {
        Formatters.formattedSavedTime(summary.timeSaved)
    }

    private var workdaySavingsText: String {
        guard summary.hasData, summary.timeSaved > 0 else {
            return String(localized: "Start dictating to build saved time.")
        }

        let fullWorkdays = Int((summary.timeSaved / TimeInterval(8 * 60 * 60)).rounded(.down))

        guard fullWorkdays >= 1 else {
            return String(
                format: String(localized: "That's %@ of workday savings."),
                Formatters.formattedCompactHoursAndMinutes(summary.timeSaved)
            )
        }

        let workdayText = String(localized: "\(fullWorkdays) workdays")
        let isOver = summary.timeSaved > (Double(fullWorkdays) * TimeInterval(8 * 60 * 60)) + 60
        let template = isOver ? String(localized: "That's over %@ saved.") : String(localized: "That's %@ saved.")

        return String(format: template, workdayText)
    }

    var body: some View {
        content
            .frame(height: 196 - (DashboardLayout.cardPadding * 2), alignment: .topLeading)
            .padding(DashboardLayout.cardPadding)
            .frame(maxWidth: .infinity, minHeight: 196, maxHeight: 196, alignment: .topLeading)
            .background(DashboardInsightCardBackground())
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            DashboardSectionLabel("Time saved")
                .padding(.bottom, 8)

            Text(summary.hasData ? savedTimeText : "–")
                .font(.app(size: 36, weight: .semibold).monospacedDigit())
                .foregroundStyle(AppTheme.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            Text(period.timeSavedContext)
                .font(.app(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Spacer(minLength: 12)

            Text(workdaySavingsText)
                .font(.app(size: 12, weight: .regular))
                .foregroundStyle(AppTheme.Text.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
