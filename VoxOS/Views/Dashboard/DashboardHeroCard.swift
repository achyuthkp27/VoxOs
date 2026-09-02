import Foundation
import SwiftUI

enum DashboardHeroHeadline {
    case calculatingProgress
    case startRecordingProgress
    case savedTime(String)
}

struct DashboardHeroCard: View {
    private static let headlineFont: Font = .app(size: 23, weight: .semibold)
    private static let highlightedHeadlineFont: Font = .app(size: 30, weight: .bold)

    let isLocked: Bool
    let headline: DashboardHeroHeadline
    let subtext: String
    let actionTitle: LocalizedStringKey
    let actionIcon: String
    let canViewInsights: Bool
    let actionHelp: String
    let actionAccessibilityLabel: String
    let onViewInsights: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isLocked {
                lockedInsightsPrompt
            } else {
                heroCopy
            }

            HStack(spacing: 12) {
                Button(action: onViewInsights) {
                    DashboardMomentumActionLabel(
                        title: actionTitle,
                        icon: actionIcon,
                        isPrimary: canViewInsights,
                        isLocked: !canViewInsights
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canViewInsights)
                .help(actionHelp)
                .accessibilityLabel(Text(actionAccessibilityLabel))
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
        .background(DashboardImpactBackground(isLocked: isLocked))
        .voiceOSCard()
    }

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: 10) {
            headlineText
                .frame(maxWidth: 720, alignment: .leading)

            Text(subtext)
                .font(.app(size: 15, weight: .semibold))
                .foregroundStyle(DashboardMomentumBackground.subtext)
                .frame(maxWidth: 620, alignment: .leading)
        }
    }

    private var headlineText: Text {
        Text(styledHeadline)
    }

    private var styledHeadline: AttributedString {
        let highlightedValue: String
        var text: AttributedString

        switch headline {
        case .calculatingProgress:
            highlightedValue = String(localized: "VoxOS progress")
            text = AttributedString(localized: "Calculating \(highlightedValue).")
        case .startRecordingProgress:
            highlightedValue = String(localized: "VoxOS progress")
            text = AttributedString(localized: "Start recording to build \(highlightedValue).")
        case .savedTime(let value):
            highlightedValue = value
            text = AttributedString(localized: "You have saved \(highlightedValue) with VoxOS")
        }

        text.font = Self.headlineFont
        text.foregroundColor = DashboardMomentumBackground.headline

        if let highlightedRange = text.range(of: highlightedValue) {
            text[highlightedRange].font = Self.highlightedHeadlineFont
            text[highlightedRange].foregroundColor = DashboardMomentumBackground.accent
        }

        return text
    }

    private var lockedInsightsPrompt: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.Accent.fill)

                Image(systemName: "lock.fill")
                    .font(.app(size: 17, weight: .bold))
                    .foregroundStyle(DashboardMomentumBackground.accent)
            }
            .frame(width: 42, height: 42)

            Text("Continue using VoxOS to unlock stats and insights.")
                .font(.app(size: 24, weight: .semibold))
                .foregroundStyle(DashboardMomentumBackground.headline)
                .frame(maxWidth: 540, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DashboardMomentumActionLabel: View {
    private static let cornerRadius: CGFloat = 12

    let title: LocalizedStringKey
    let icon: String
    let isPrimary: Bool
    var isLocked = false

    var body: some View {
        HStack(spacing: 9) {
            Text(title)
                .lineLimit(2)

            Image(systemName: icon)
                .font(.app(size: 13, weight: .semibold))
        }
        .font(.app(size: 13, weight: .semibold))
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 22)
        .frame(minHeight: 40)
        .background(backgroundColor)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(borderColor, lineWidth: 1))
        .shadow(color: shadowColor, radius: 2, y: 2)
    }

    private var foregroundColor: Color {
        if isPrimary {
            return Color.white
        }

        return isLocked ? DashboardMomentumBackground.subtext : AppTheme.Text.primary
    }

    private var backgroundColor: Color {
        if isPrimary {
            return DashboardMomentumBackground.accent
        }

        return isLocked ? AppTheme.Surface.subtle : AppTheme.Surface.card
    }

    private var borderColor: Color {
        if isPrimary {
            return Color.clear
        }

        return AppTheme.Border.control
    }

    private var shadowColor: Color {
        isPrimary ? AppTheme.Accent.shadow : AppTheme.Shadow.card
    }
}

private struct DashboardImpactBackground: View {
    var isLocked = false

    var body: some View {
        // A faint accent bloom in the far corner; the glass slab itself is the card.
        RadialGradient(
            colors: [AppTheme.Accent.primary.opacity(isLocked ? 0.18 : 0.32), .clear],
            center: .init(x: 1.05, y: 1.1), startRadius: 0, endRadius: 560)
    }
}

private struct DashboardMomentumBackground {
    static let accent = AppTheme.Accent.primary
    static let headline = AppTheme.Text.heading
    static let subtext = AppTheme.Text.secondary
}
