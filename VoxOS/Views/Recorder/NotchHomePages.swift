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
    /// Notes kept on this Mac, written in the card.
    case notes

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
        case .notes: return "note.text"
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
        case .notes: return String(localized: "Notes")
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

/// The bar under the open card: one button per page in the user's order, the one shown lit, and
/// Pomodoro on its own round button beside it, ringed while a timer runs. Swiping sideways on the
/// card still turns pages; this is for a mouse, and to jump straight to one.
struct NotchHomeNavBar: View {
    let pages: [NotchHomePage]
    let current: NotchHomePage
    let onSelect: (NotchHomePage) -> Void
    @ObservedObject var timers: NotchTimers

    static let height: CGFloat = 34
    /// Between the card's bottom edge and the bar.
    static let gap: CGFloat = 10
    /// The room the bar takes under the card, with a little for its shadow.
    static var space: CGFloat { gap + height + 8 }

    private var barPages: [NotchHomePage] { pages.filter { $0 != .timer } }

    var body: some View {
        HStack(spacing: 10) {
            if !barPages.isEmpty {
                HStack(spacing: 2) {
                    ForEach(barPages) { page in
                        NotchNavButton(symbol: page.symbol, title: page.title, selected: page == current, width: 32) {
                            onSelect(page)
                        }
                    }
                }
                .padding(.horizontal, 4)
                .frame(height: Self.height)
                .background(NotchNavSurface(shape: Capsule()))
            }
            if pages.contains(.timer) {
                ZStack {
                    NotchNavButton(
                        symbol: NotchHomePage.timer.symbol, title: NotchHomePage.timer.title,
                        selected: current == .timer, width: Self.height - 8
                    ) { onSelect(.timer) }
                    if let running = timers.running {
                        NotchTicking(every: 1, while: !running.isPaused) { context in
                            NotchTimerRing(
                                progress: running.progress(at: context.date), kind: running.kind, lineWidth: 2
                            )
                            .frame(width: Self.height - 6, height: Self.height - 6)
                            .allowsHitTesting(false)
                        }
                    }
                }
                .frame(width: Self.height, height: Self.height)
                .background(NotchNavSurface(shape: Circle()))
            }
        }
        .fixedSize()
    }
}

/// The bar's glass: the card's own material, a little lighter so it reads as a control.
private struct NotchNavSurface<S: Shape>: View {
    let shape: S

    var body: some View {
        shape.fill(Color.black.opacity(0.28))
            .liquidGlass(in: shape, tint: NotchDesign.glassTint)
    }
}

private struct NotchNavButton: View {
    let symbol: String
    let title: String
    let selected: Bool
    let width: CGFloat
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(selected ? 1 : hovered ? 0.85 : 0.6))
                .frame(width: width, height: NotchHomeNavBar.height - 8)
                .background(Capsule().fill(.white.opacity(selected ? 0.2 : hovered ? 0.1 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(Text(verbatim: title))
        .accessibilityLabel(Text(verbatim: title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Timer
