import AppKit
import CoreAudio
import SwiftUI
import UniformTypeIdentifiers

/// The open notch's pages, in the order a sideways swipe walks them.
enum NotchHomePage: String, CaseIterable, Identifiable {
    case music
    case today
    case weather
    case timer
    case shelf
    /// Per-app volume, with the clipboard, the camera mirror, keeping awake and pinning.
    case sound

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .music: return "music.note"
        case .today: return "calendar"
        case .weather: return "cloud.sun.fill"
        case .timer: return "timer"
        case .shelf: return "tray"
        // A speaker, not sliders: in the corner, sliders read as Settings.
        case .sound: return "speaker.wave.2.fill"
        }
    }

    var title: String {
        switch self {
        case .music: return String(localized: "Music")
        case .today: return String(localized: "Calendar")
        case .weather: return String(localized: "Weather")
        case .timer: return String(localized: "Pomodoro")
        case .shelf: return String(localized: "Shelf")
        case .sound: return String(localized: "Sound")
        }
    }

    /// Music only while there is a track; a page switched off in Settings never, whatever the
    /// state. When every page is off, the day stays as the one page the notch can still show.
    static func available(hasTrack: Bool, defaults: UserDefaults = .standard) -> [NotchHomePage] {
        let disabled = NotchPageLayout.disabled(from: defaults)
        let pages = NotchPageLayout.ordered(from: defaults).filter { !disabled.contains($0) }
        let showing = hasTrack ? pages : pages.filter { $0 != .music }
        return showing.isEmpty ? [.today] : showing
    }

    /// What opening the notch shows: files being dragged in go to the shelf, a meeting about to
    /// start to the calendar, then whatever is running — a timer, then music — and otherwise the
    /// first page that is on. A page switched off falls through to that first page too.
    static func preferred(
        hasTrack: Bool,
        timerRunning: Bool,
        dropping: Bool,
        meeting: Bool = false,
        defaults: UserDefaults = .standard
    ) -> NotchHomePage {
        let pages = available(hasTrack: hasTrack, defaults: defaults)
        let wanted: NotchHomePage =
            dropping ? .shelf : meeting ? .today : timerRunning ? .timer : hasTrack ? .music : .today
        return pages.contains(wanted) ? wanted : pages.first ?? .today
    }
}

/// The page you are on, in the top-right corner. Swipe sideways to turn pages; a click moves
/// to the next one, for a mouse.
struct NotchHomePageButton: View {
    let page: NotchHomePage
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: page.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(hovered ? 0.95 : 0.7))
                .frame(width: 24, height: 20)
                .background(Capsule().fill(.white.opacity(hovered ? 0.14 : 0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(String(localized: "\(page.title) · swipe sideways for the next page"))
        .accessibilityLabel(Text(page.title))
        .accessibilityHint(Text("Shows the next page"))
    }
}

/// A page's name in the left wing, so the notch row is never an empty black strip.
struct NotchHomePageLabel: View {
    let text: String

    var body: some View {
        Text(verbatim: text.uppercased())
            .font(.appMono(size: 10, weight: .medium))
            .tracking(0.6)
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1)
    }
}

// MARK: - Timer
