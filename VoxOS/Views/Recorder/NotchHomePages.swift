import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The open notch's pages, switched from the small icons in its top-right corner.
enum NotchHomePage: String, CaseIterable, Identifiable {
    case music
    case timer
    case today
    case shelf

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .music: return "music.note"
        case .timer: return "timer"
        case .today: return "calendar"
        case .shelf: return "tray"
        }
    }

    var title: String {
        switch self {
        case .music: return String(localized: "Music")
        case .timer: return String(localized: "Timer")
        case .today: return String(localized: "Today")
        case .shelf: return String(localized: "Shelf")
        }
    }

    /// Music only while there is a track; the rest always.
    static func available(hasTrack: Bool) -> [NotchHomePage] {
        hasTrack ? allCases : allCases.filter { $0 != .music }
    }

    /// What opening the notch shows: files being dragged in go to the shelf, then whatever is
    /// running — a timer, then music — and otherwise the day.
    static func preferred(hasTrack: Bool, timerRunning: Bool, dropping: Bool) -> NotchHomePage {
        if dropping { return .shelf }
        if timerRunning { return .timer }
        if hasTrack { return .music }
        return .today
    }
}

struct NotchHomePageSelector: View {
    let pages: [NotchHomePage]
    let selection: NotchHomePage
    let onSelect: (NotchHomePage) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(pages) { page in
                Button {
                    onSelect(page)
                } label: {
                    Image(systemName: page.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(page == selection ? 0.95 : 0.4))
                        .frame(width: 24, height: 20)
                        .background(Capsule().fill(.white.opacity(page == selection ? 0.12 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(page.title)
                .accessibilityLabel(Text(page.title))
                .accessibilityAddTraits(page == selection ? .isSelected : [])
            }
        }
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

struct NotchTimerPage: View {
    @ObservedObject var timers: NotchTimers

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let running = timers.running {
                runningView(running, now: context.date)
            } else {
                startView
            }
        }
        .padding(.horizontal, AgentComposer.panelInset)
        .padding(.bottom, NotchHome.Card.bottom)
    }

    private func runningView(_ timer: NotchTimer, now: Date) -> some View {
        HStack(spacing: 18) {
            NotchTimerRing(progress: timer.progress(at: now), kind: timer.kind, lineWidth: 4)
                .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: NotchTimers.clock(timer.remaining(at: now)))
                    .font(.appMono(size: 32, weight: .semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text(verbatim: subtitle(timer))
                    .font(.app(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if timer.kind.isPomodoro {
                NotchRoundButton(symbol: "forward.end.fill", label: "Skip") { timers.skip() }
            }
            NotchRoundButton(symbol: "xmark", label: "Stop") { timers.cancel() }
        }
        .frame(maxHeight: .infinity)
    }

    private func subtitle(_ timer: NotchTimer) -> String {
        switch timer.kind {
        case .countdown: return timer.label.isEmpty ? String(localized: "Timer") : timer.label
        case .focus: return String(localized: "Focus · \(timer.completedFocus + 1) of 4")
        case .shortBreak: return String(localized: "Short break")
        case .longBreak: return String(localized: "Long break")
        }
    }

    private var startView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer(minLength: 0)
            Text("Start a timer")
                .font(.app(size: 15, weight: .semibold))
                .foregroundStyle(.white)
            HStack(spacing: 8) {
                ForEach([5, 15, 25], id: \.self) { minutes in
                    NotchChip(title: "\(minutes) min") { timers.startCountdown(minutes: Double(minutes)) }
                }
                NotchChip(title: String(localized: "Pomodoro"), prominent: true) { timers.startPomodoro() }
            }
            Text("Or say it: \u{201C}start a 25 minute pomodoro\u{201D}.")
                .font(.app(size: 11))
                .foregroundStyle(.white.opacity(0.4))
            Spacer(minLength: 0)
        }
    }
}

/// Progress around a circle, in the colour of what is running: focus, break, or a plain timer.
struct NotchTimerRing: View {
    let progress: Double
    let kind: NotchTimer.Kind
    var lineWidth: CGFloat = 2.5

    static func color(for kind: NotchTimer.Kind) -> Color {
        switch kind {
        case .countdown: return .white
        case .focus: return Color(red: 1, green: 0.45, blue: 0.4)
        case .shortBreak, .longBreak: return Color(red: 0.42, green: 0.86, blue: 0.56)
        }
    }

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(Self.color(for: kind), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Today

struct NotchTodayPage: View {
    @ObservedObject var today: NotchToday

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(alignment: .center, spacing: 22) {
                dateAndWeather(now: context.date)
                    .frame(width: 128, alignment: .leading)
                Rectangle().fill(.white.opacity(0.08)).frame(width: 1, height: 72)
                events(now: context.date)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, AgentComposer.panelInset)
        .padding(.bottom, NotchHome.Card.bottom)
        .onAppear { today.refresh() }
    }

    private func dateAndWeather(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: now.formatted(.dateTime.weekday(.wide)))
                .font(.app(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Text(verbatim: now.formatted(.dateTime.day()))
                .font(.app(size: 34, weight: .semibold))
                .foregroundStyle(.white)
            if let weather = today.weather {
                HStack(spacing: 5) {
                    Image(systemName: weather.symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 12))
                    Text(verbatim: "\(weather.temperature)°")
                        .font(.app(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    if let high = weather.high, let low = weather.low {
                        Text(verbatim: "\(high)° / \(low)°")
                            .font(.app(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .help(weather.place.map { "\(weather.conditions) · \($0)" } ?? weather.conditions)
            }
        }
    }

    @ViewBuilder
    private func events(now: Date) -> some View {
        switch today.calendarAccess {
        case .notDetermined:
            VStack(alignment: .leading, spacing: 8) {
                Text("See what's next")
                    .font(.app(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                NotchChip(title: String(localized: "Allow Calendar"), prominent: true) {
                    today.requestCalendarAccess()
                }
            }
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                Text("Calendar access is off")
                    .font(.app(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                NotchChip(title: String(localized: "Open Settings")) {
                    if let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
                    {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        case .granted:
            if today.events.isEmpty {
                Text("Nothing else today")
                    .font(.app(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(today.events) { event in
                        HStack(spacing: 9) {
                            RoundedRectangle(cornerRadius: 1.5).fill(event.color).frame(width: 3, height: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: event.title)
                                    .font(.app(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(verbatim: NotchToday.when(event, now: now))
                                    .font(.app(size: 11))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Shelf

struct NotchShelfPage: View {
    @ObservedObject var shelf: NotchShelf
    let dropping: Bool

    var body: some View {
        Group {
            if shelf.items.isEmpty || dropping {
                dropArea
            } else {
                HStack(alignment: .center, spacing: 6) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(shelf.items) { item in
                                NotchShelfTile(item: item) { shelf.remove(item.id) }
                            }
                        }
                    }
                    NotchRoundButton(symbol: "trash", label: "Clear the shelf") { shelf.clear() }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, AgentComposer.panelInset)
        .padding(.bottom, NotchHome.Card.bottom)
        .onAppear { shelf.prune() }
    }

    private var dropArea: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
                .white.opacity(dropping ? 0.6 : 0.2), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])
            )
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(dropping ? 0.08 : 0.02))
            )
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: dropping ? "tray.and.arrow.down.fill" : "tray")
                        .font(.system(size: 20, weight: .medium))
                    Text(dropping ? "Drop to keep it here" : "Drop files on the notch to keep them here")
                        .font(.app(size: 12))
                }
                .foregroundStyle(.white.opacity(dropping ? 0.9 : 0.45))
            }
            .padding(.top, 4)
    }
}

/// A file on the shelf: its icon and name. Drag it out to use it; it stays on the shelf.
private struct NotchShelfTile: View {
    let item: NotchShelf.Item
    let onRemove: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(spacing: 4) {
            Image(nsImage: NotchShelf.icon(for: item))
                .resizable()
                .frame(width: 40, height: 40)
            Text(verbatim: item.name)
                .font(.app(size: 10))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: 66, height: 70)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(hovered ? 0.08 : 0)))
        .overlay(alignment: .topTrailing) {
            if hovered {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.8), .black.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Remove \(item.name)"))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .help(item.path)
    }
}

// MARK: - Controls

struct NotchChip: View {
    let title: String
    var prominent = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.app(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var fill: Color {
        prominent ? AppTheme.Accent.primary.opacity(hovered ? 1 : 0.85) : .white.opacity(hovered ? 0.16 : 0.09)
    }
}

struct NotchRoundButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(hovered ? 1 : 0.75))
                .frame(width: 32, height: 32)
                .background(Circle().fill(.white.opacity(hovered ? 0.16 : 0.09)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(Text(label))
    }
}
