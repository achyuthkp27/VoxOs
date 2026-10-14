import Foundation
import SwiftUI

/// What the hero says, decided by `DashboardContent` from the loaded stats.
enum DashboardHeroState: Equatable {
    case loading
    /// Stats failed to load and nothing is cached; the card's action becomes a retry.
    case failed
    case locked
    /// No dictation recorded yet. Carries the recording shortcut so the copy can name the key.
    case firstRun(shortcut: String?)
    /// Dictated before. All-time figures lead; the week drives the prism and its caption.
    case active(
        totalWords: Int,
        totalSaved: TimeInterval,
        weekWords: Int,
        weekSessions: Int,
        previousWeekWords: Int
    )
}

struct DashboardHeroAction {
    let title: LocalizedStringKey
    let icon: String
    let help: String
    let isEnabled: Bool
    let perform: () -> Void
}

/// The page's one statement: the time VoxOS has saved you, with the week drawn as the prism
/// beside (wide) or under (narrow) it. The saved figure is the only accent-coloured text.
struct DashboardHeroCard: View {
    private static let headlineSize: CGFloat = 26

    let state: DashboardHeroState
    let days: [DashboardProductivityPoint]
    let modeShares: [DashboardModeShare]
    /// True when the card is wide enough to sit the prism beside the copy.
    let isSplit: Bool
    let action: DashboardHeroAction?

    var body: some View {
        Group {
            if isSplit {
                HStack(alignment: .center, spacing: 28) {
                    copy
                    prism
                        .frame(minWidth: 220, maxWidth: 340)
                }
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    copy
                    prism
                }
            }
        }
        .padding(DashboardLayout.heroPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DashboardInsightCardBackground(isTinted: true))
        .animation(.easeOut(duration: 0.2), value: state)
    }

    private var weekIsActive: Bool {
        if case .active(_, _, let weekWords, let weekSessions, _) = state {
            return weekWords > 0 || weekSessions > 0
        }
        return false
    }

    private var prism: some View {
        VStack(alignment: .leading, spacing: 8) {
            DashboardSectionLabel("Last 7 days by mode")

            DashboardPrism(days: days, shares: modeShares, isActive: weekIsActive)
                .frame(height: isSplit ? 118 : 104)

            if let weekCaption {
                Text(weekCaption)
                    .font(.app(size: 12, weight: .regular))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(headline)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520, alignment: .leading)
                .contentTransition(.opacity)

            if let detail {
                Text(detail)
                    .font(.app(size: 13, weight: .regular))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520, alignment: .leading)
            }

            if let action {
                Button(action: action.perform) {
                    HStack(spacing: 6) {
                        Text(action.title)
                        Image(systemName: action.icon)
                            .font(.app(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.voiceOSCompact)
                .disabled(!action.isEnabled)
                .help(action.help)
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The serif headline with its figure lifted into the accent, so the number carries the
    /// hierarchy.
    private var headline: AttributedString {
        let figure: String?
        let plain: String

        switch state {
        case .loading:
            figure = nil
            plain = String(localized: "Adding up your dictation…")
        case .failed:
            figure = nil
            plain = String(localized: "Your stats couldn’t be loaded.")
        case .locked:
            figure = nil
            plain = String(localized: "Keep dictating to unlock your stats.")
        case .firstRun:
            figure = nil
            plain = String(localized: "Your first dictation is one shortcut away.")
        case .active(let totalWords, let totalSaved, _, _, _):
            if totalSaved >= 60 {
                let savedText = Formatters.formattedSavedTime(totalSaved)
                figure = savedText
                plain = String(localized: "You have saved \(savedText) with VoxOS")
            } else {
                let wordsText = Self.wordsText(totalWords)
                figure = wordsText
                plain = String(localized: "You have dictated \(wordsText) with VoxOS")
            }
        }

        var text = AttributedString(plain)
        text.font = Font.appDisplay(size: Self.headlineSize)
        text.foregroundColor = AppTheme.Text.primary

        if let figure, let range = text.range(of: figure) {
            text[range].foregroundColor = AppTheme.Accent.primary
        }

        return text
    }

    private var detail: String? {
        switch state {
        case .loading:
            return nil
        case .failed:
            return String(localized: "Something went wrong while reading your history.")
        case .locked:
            return nil
        case .firstRun(let shortcut):
            guard let shortcut else {
                return String(
                    localized:
                        "Set a recording shortcut, then hold it in any text field and speak. Words and time saved add up here."
                )
            }
            return String(
                localized:
                    "Click into any text field, hold \(shortcut) and speak, then let go to paste. Words and time saved add up here."
            )
        case .active(let totalWords, _, _, _, _):
            let dictated = String(
                localized: "Dictated \(Formatters.formattedCompactNumber(totalWords)) words")
            guard let comparison = Self.bookComparison(totalWords) else { return dictated }
            return "\(dictated) · \(comparison)"
        }
    }

    /// Under the prism: how this week compares with the one before.
    private var weekCaption: String? {
        switch state {
        case .active(_, _, let weekWords, let weekSessions, let previousWeekWords):
            guard weekSessions > 0 else {
                return String(localized: "Nothing dictated in the last 7 days.")
            }
            return Self.weekDetail(words: weekWords, sessions: weekSessions, previousWeekWords: previousWeekWords)
        case .firstRun:
            return String(localized: "Your week shows up here, split by the mode you used.")
        case .loading, .failed, .locked:
            return nil
        }
    }

    private static func bookComparison(_ words: Int) -> String? {
        switch DashboardProgressBenchmark.equivalence(for: words) {
        case .matched(let title):
            return String(localized: "as long as \(title)")
        case .repeated(let title, let count):
            return String(localized: "\(title), \(Formatters.formattedNumber(count)) times over")
        case .remaining(let remaining, let title):
            guard remaining > 0, !title.isEmpty else { return nil }
            return String(localized: "\(Formatters.formattedNumber(remaining)) words from \(title)")
        }
    }

    private static func wordsText(_ words: Int) -> String {
        let count = Formatters.formattedNumber(words)
        return words == 1 ? String(localized: "\(count) word") : String(localized: "\(count) words")
    }

    private static func weekDetail(words: Int, sessions: Int, previousWeekWords: Int) -> String {
        let wordsText = wordsText(words)
        let sessionsText =
            sessions == 1
            ? String(localized: "\(wordsText) in 1 session")
            : String(localized: "\(wordsText) in \(Formatters.formattedNumber(sessions)) sessions")

        guard previousWeekWords > 0 else {
            return String(localized: "\(sessionsText).")
        }

        let change = Double(words - previousWeekWords) / Double(previousWeekWords)
        let percent = Int((abs(change) * 100).rounded())

        if percent < 5 {
            return String(localized: "\(sessionsText), about the same as the 7 days before.")
        }

        return change > 0
            ? String(localized: "\(sessionsText), \(percent)% more than the 7 days before.")
            : String(localized: "\(sessionsText), \(percent)% fewer than the 7 days before.")
    }
}
