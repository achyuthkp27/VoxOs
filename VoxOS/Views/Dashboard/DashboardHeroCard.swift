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
    /// Dictated before, but not in the last seven days.
    case quietWeek(allTimeWords: Int, allTimeSaved: TimeInterval)
    case week(words: Int, saved: TimeInterval, sessions: Int, previousWeekWords: Int)
}

struct DashboardHeroAction {
    let title: LocalizedStringKey
    let icon: String
    let help: String
    let isEnabled: Bool
    let perform: () -> Void
}

/// The page's one statement: what VoxOS did for you in the last seven days, as a sentence, beside
/// the week drawn as a voice waveform. The waveform is the page's only accent colour.
struct DashboardHeroCard: View {
    private static let sentenceSize: CGFloat = 22

    let state: DashboardHeroState
    let days: [DashboardProductivityPoint]
    let isWide: Bool
    let action: DashboardHeroAction?

    var body: some View {
        Group {
            if isWide {
                HStack(alignment: .center, spacing: 36) {
                    copy
                    DashboardWeekWaveform(days: days, isActive: showsActivity)
                        .frame(width: 236, height: 112)
                }
            } else {
                VStack(alignment: .leading, spacing: 22) {
                    copy
                    DashboardWeekWaveform(days: days, isActive: showsActivity)
                        .frame(height: 92)
                }
            }
        }
        .dashboardCard(padding: DashboardLayout.heroPadding)
        .animation(.easeOut(duration: 0.2), value: state)
    }

    private var showsActivity: Bool {
        if case .week = state { return true }
        return false
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 10) {
            DashboardSectionLabel(eyebrow)

            Text(sentence)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
                .contentTransition(.opacity)

            if let detail {
                Text(detail)
                    .font(.app(size: 13, weight: .regular))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560, alignment: .leading)
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
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var eyebrow: LocalizedStringKey {
        switch state {
        case .firstRun: return "Get started"
        default: return "Last 7 days"
        }
    }

    /// The sentence in secondary text with its figures lifted to primary, so the numbers carry the
    /// hierarchy without a second colour.
    private var sentence: AttributedString {
        let figures: [String]
        let plain: String

        switch state {
        case .loading:
            figures = []
            plain = String(localized: "Adding up your dictation…")
        case .failed:
            figures = []
            plain = String(localized: "Your stats couldn’t be loaded.")
        case .locked:
            figures = []
            plain = String(localized: "Keep dictating to unlock your stats.")
        case .firstRun:
            figures = []
            plain = String(localized: "Your first dictation is one shortcut away.")
        case .quietWeek:
            figures = []
            plain = String(localized: "Nothing dictated in the last 7 days.")
        case .week(let words, let saved, _, _):
            let wordsText = Self.wordsText(words)
            if saved >= 60 {
                let savedText = Formatters.formattedSavedTime(saved)
                figures = [wordsText, savedText]
                plain = String(localized: "You dictated \(wordsText) and saved \(savedText) of typing.")
            } else {
                figures = [wordsText]
                plain = String(localized: "You dictated \(wordsText).")
            }
        }

        var text = AttributedString(plain)
        text.font = Font.app(size: Self.sentenceSize, weight: .medium)
        text.foregroundColor = figures.isEmpty ? AppTheme.Text.primary : AppTheme.Text.secondary

        for figure in figures {
            if let range = text.range(of: figure) {
                text[range].font = Font.app(size: Self.sentenceSize, weight: .semibold)
                text[range].foregroundColor = AppTheme.Text.primary
            }
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
        case .quietWeek(let words, let saved):
            let wordsText = Self.wordsText(words)
            guard saved >= 60 else {
                return String(localized: "So far you’ve dictated \(wordsText) with VoxOS.")
            }
            return String(
                localized: "So far you’ve dictated \(wordsText) and saved \(Formatters.formattedSavedTime(saved)).")
        case .week(let words, _, let sessions, let previousWeekWords):
            return Self.weekDetail(words: words, sessions: sessions, previousWeekWords: previousWeekWords)
        }
    }

    private static func wordsText(_ words: Int) -> String {
        let count = Formatters.formattedNumber(words)
        return words == 1 ? String(localized: "\(count) word") : String(localized: "\(count) words")
    }

    private static func weekDetail(words: Int, sessions: Int, previousWeekWords: Int) -> String {
        let count = Formatters.formattedNumber(sessions)
        let sessionsText =
            sessions == 1
            ? String(localized: "Across 1 session") : String(localized: "Across \(count) sessions")

        guard previousWeekWords > 0 else {
            return String(localized: "\(sessionsText).")
        }

        let change = Double(words - previousWeekWords) / Double(previousWeekWords)
        let percent = Int((abs(change) * 100).rounded())

        if percent < 5 {
            return String(localized: "\(sessionsText), about the same as the 7 days before.")
        }

        return change > 0
            ? String(localized: "\(sessionsText), \(percent)% more words than the 7 days before.")
            : String(localized: "\(sessionsText), \(percent)% fewer words than the 7 days before.")
    }
}

/// Seven days as a mirrored voice waveform: one bar per day, its height the words dictated that
/// day. With no activity it is a flat line, which reads as silence rather than as a broken chart.
private struct DashboardWeekWaveform: View {
    private static let restingHeight: CGFloat = 4
    private static let labelHeight: CGFloat = 16

    let days: [DashboardProductivityPoint]
    let isActive: Bool

    private var maxWords: Int {
        max(days.map(\.words).max() ?? 0, 1)
    }

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                HStack(alignment: .center, spacing: 0) {
                    ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                        Capsule(style: .continuous)
                            .fill(barColor(for: day, isToday: index == days.count - 1))
                            .frame(width: barWidth(in: geometry.size.width))
                            .frame(height: barHeight(for: day, available: geometry.size.height))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .help(Text(verbatim: "\(day.accessibilityLabel): \(Formatters.formattedNumber(day.words))"))
                    }
                }
            }

            HStack(spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    Text(verbatim: day.label)
                        .font(.app(size: 10, weight: index == days.count - 1 ? .semibold : .medium))
                        .foregroundStyle(index == days.count - 1 ? AppTheme.Text.secondary : AppTheme.Text.muted)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: Self.labelHeight)
        }
        .animation(.easeOut(duration: 0.35), value: days.map(\.words))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Words dictated each day, last 7 days")
        .accessibilityValue(accessibilityValue)
    }

    private func barWidth(in width: CGFloat) -> CGFloat {
        let slot = width / CGFloat(max(days.count, 1))
        return min(max(slot * 0.42, 6), 16)
    }

    private func barHeight(for day: DashboardProductivityPoint, available: CGFloat) -> CGFloat {
        guard isActive, day.words > 0 else { return Self.restingHeight }
        // Square root keeps a light day visible next to a heavy one.
        let share = (Double(day.words) / Double(maxWords)).squareRoot()
        return max(Self.restingHeight * 2, available * CGFloat(share))
    }

    private func barColor(for day: DashboardProductivityPoint, isToday: Bool) -> Color {
        guard isActive, day.words > 0 else { return AppTheme.Border.control }
        return isToday ? AppTheme.Accent.primary : AppTheme.Accent.primary.opacity(0.55)
    }

    private var accessibilityValue: String {
        days
            .map { "\($0.accessibilityLabel) \(Formatters.formattedNumber($0.words))" }
            .joined(separator: ", ")
    }
}
