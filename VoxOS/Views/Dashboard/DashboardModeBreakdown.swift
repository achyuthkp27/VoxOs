import SwiftUI

/// The prism, as bars: each mode's share of the range's words in its spectrum colour, largest
/// first. Modes past the fifth fold into "Other" so the panel stays short.
struct DashboardModeBreakdown: View {
    private static let maxRows = 5
    private static let nameWidth: CGFloat = 116

    let shares: [DashboardModeShare]
    let isLoaded: Bool

    @ObservedObject private var modeManager = ModeManager.shared

    private struct Row: Identifiable {
        let id: String
        let name: String
        let color: Color
        let words: Int
        let sessions: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardSectionLabel(title: "By mode") {
                if isLoaded, !rows.isEmpty {
                    Text("Share of words")
                        .font(.app(size: 11, weight: .regular))
                        .foregroundStyle(AppTheme.Text.muted)
                }
            }

            if !isLoaded {
                message(String(localized: "Your modes show up here once your stats load."))
            } else if rows.isEmpty {
                message(
                    String(localized: "Nothing dictated in this period. Each mode you use gets its own colour here."))
            } else {
                VStack(spacing: 12) {
                    ForEach(rows) { row in
                        rowView(row)
                    }
                }
                .padding(.top, 16)
            }
        }
        .dashboardCard(fillsHeight: true)
    }

    private var totalWords: Int {
        shares.reduce(0) { $0 + $1.words }
    }

    private var totalSessions: Int {
        shares.reduce(0) { $0 + $1.sessionCount }
    }

    private var rows: [Row] {
        let visible = shares.filter { $0.words > 0 || $0.sessionCount > 0 }
        let leading = visible.prefix(Self.maxRows)
        var rows = leading.map { share in
            Row(
                id: share.id,
                name: share.modeName ?? String(localized: "No mode recorded"),
                color: ModeSpectrum.color(forModeNamed: share.modeName, in: modeManager.configurations),
                words: share.words,
                sessions: share.sessionCount
            )
        }

        let rest = visible.dropFirst(Self.maxRows)
        if !rest.isEmpty {
            rows.append(
                Row(
                    id: "dashboard-other-modes",
                    name: String(localized: "Other"),
                    color: AppTheme.Text.muted,
                    words: rest.reduce(0) { $0 + $1.words },
                    sessions: rest.reduce(0) { $0 + $1.sessionCount }
                )
            )
        }
        return rows
    }

    /// Words when there are any; sessions otherwise, so a range of empty dictations still splits.
    private func share(of row: Row) -> Double {
        if totalWords > 0 { return Double(row.words) / Double(totalWords) }
        guard totalSessions > 0 else { return 0 }
        return Double(row.sessions) / Double(totalSessions)
    }

    private func rowView(_ row: Row) -> some View {
        let fraction = share(of: row)
        let percent = Int((fraction * 100).rounded())

        return HStack(spacing: 12) {
            HStack(spacing: 8) {
                Circle()
                    .fill(row.color)
                    .frame(width: 7, height: 7)
                Text(verbatim: row.name)
                    .font(.app(size: 13, weight: .regular))
                    .foregroundStyle(AppTheme.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: Self.nameWidth, alignment: .leading)

            Capsule()
                .fill(AppTheme.Surface.control)
                .frame(height: 8)
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(row.color)
                            .frame(width: max(geometry.size.width * CGFloat(fraction), fraction > 0 ? 6 : 0))
                    }
                }
                .frame(maxWidth: .infinity)

            Text(verbatim: percent < 1 && fraction > 0 ? "<1%" : "\(percent)%")
                .font(.appMono(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primary)
                .frame(width: 40, alignment: .trailing)

            Text(verbatim: Formatters.formattedCompactNumber(row.words))
                .font(.appMono(size: 11, weight: .regular))
                .foregroundStyle(AppTheme.Text.secondary)
                .frame(width: 44, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: row.name))
        .accessibilityValue(
            Text("\(percent)% of words, \(Formatters.formattedNumber(row.words)) words")
        )
    }

    private func message(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.app(size: 12, weight: .regular))
            .foregroundStyle(AppTheme.Text.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 12)
    }
}
