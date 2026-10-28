import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The open notch's pages, in the order a sideways swipe walks them.
enum NotchHomePage: String, CaseIterable, Identifiable {
    case music
    case today
    case reminders
    case timer
    case shelf
    /// Per-app volume.
    case sound
    case mirror

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .music: return "music.note"
        case .today: return "calendar"
        case .reminders: return "checklist"
        case .timer: return "timer"
        case .shelf: return "tray"
        case .sound: return "slider.horizontal.3"
        case .mirror: return "person.crop.square"
        }
    }

    var title: String {
        switch self {
        case .music: return String(localized: "Music")
        case .today: return String(localized: "Calendar")
        case .reminders: return String(localized: "Reminders")
        case .timer: return String(localized: "Pomodoro")
        case .shelf: return String(localized: "Shelf")
        case .sound: return String(localized: "Sound")
        case .mirror: return String(localized: "Mirror")
        }
    }

    /// Music only while there is a track; Sound and Mirror when switched on; the rest always.
    static func available(hasTrack: Bool, sound: Bool = true, mirror: Bool = true) -> [NotchHomePage] {
        allCases.filter { page in
            switch page {
            case .music: return hasTrack
            case .sound: return sound
            case .mirror: return mirror
            default: return true
            }
        }
    }

    /// What opening the notch shows: files being dragged in go to the shelf, a meeting about to
    /// start to the calendar, then whatever is running — a timer, then music — and otherwise the
    /// day.
    static func preferred(hasTrack: Bool, timerRunning: Bool, dropping: Bool, meeting: Bool = false) -> NotchHomePage {
        if dropping { return .shelf }
        if meeting { return .today }
        if timerRunning { return .timer }
        if hasTrack { return .music }
        return .today
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

/// A ring with the time in it, what is running, and the controls; or, idle, a ready ring and
/// one clear way to start.
struct NotchTimerPage: View {
    @ObservedObject var timers: NotchTimers
    static let ringSize: CGFloat = 92

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 22) {
                ring(now: context.date)
                if let running = timers.running {
                    runningDetails(running)
                } else {
                    startDetails
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, AgentComposer.panelInset)
        .padding(.bottom, NotchHome.Card.bottom)
    }

    private func ring(now: Date) -> some View {
        let running = timers.running
        return ZStack {
            NotchTimerRing(
                progress: running?.progress(at: now) ?? 0, kind: running?.kind ?? .focus, lineWidth: 5)
            VStack(spacing: 1) {
                Text(verbatim: NotchTimers.clock(running?.remaining(at: now) ?? timers.durations.focus))
                    .font(.appMono(size: 21, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(running == nil ? 0.45 : 1))
                if running?.isPaused == true {
                    Text("Paused")
                        .font(.app(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: Self.ringSize, height: Self.ringSize)
    }

    private func runningDetails(_ timer: NotchTimer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: title(timer))
                    .font(.app(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if timer.kind.isPomodoro { cycleDots(timer) }
            }
            HStack(spacing: 8) {
                NotchRoundButton(
                    symbol: timer.isPaused ? "play.fill" : "pause.fill", label: timer.isPaused ? "Resume" : "Pause"
                ) {
                    if timer.isPaused { timers.resume() } else { timers.pause() }
                }
                if timer.kind.isPomodoro {
                    NotchRoundButton(symbol: "forward.end.fill", label: "Skip") { timers.skip() }
                }
                NotchRoundButton(symbol: "stop.fill", label: "Stop") { timers.cancel() }
            }
        }
    }

    /// Four dots for the four focus sessions before a long break: done ones filled, the one
    /// under way ringed.
    private func cycleDots(_ timer: NotchTimer) -> some View {
        let done = timer.completedFocus % timers.durations.focusesBeforeLongBreak
        return HStack(spacing: 5) {
            ForEach(0..<timers.durations.focusesBeforeLongBreak, id: \.self) { index in
                Circle()
                    .fill(index < done ? NotchTimerRing.color(for: .focus) : .clear)
                    .overlay(
                        Circle().strokeBorder(
                            .white.opacity(index == done && timer.kind == .focus ? 0.8 : 0.25), lineWidth: 1)
                    )
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityLabel(Text("Focus \(done + 1) of \(timers.durations.focusesBeforeLongBreak)"))
    }

    private func title(_ timer: NotchTimer) -> String {
        switch timer.kind {
        case .countdown: return timer.label.isEmpty ? String(localized: "Timer") : timer.label
        case .focus: return String(localized: "Focus")
        case .shortBreak: return String(localized: "Short break")
        case .longBreak: return String(localized: "Long break")
        }
    }

    private var startDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Focus")
                    .font(.app(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text("25 min of focus, then 5 min off")
                    .font(.app(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
            }
            HStack(spacing: 6) {
                NotchChip(title: String(localized: "Start focus"), prominent: true) { timers.startPomodoro() }
                NotchChip(title: String(localized: "5 min")) { timers.startCountdown(minutes: 5) }
                NotchChip(title: String(localized: "15 min")) { timers.startCountdown(minutes: 15) }
            }
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
                            if NotchToday.canJoin(event, now: now) {
                                Spacer(minLength: 6)
                                NotchJoinButton { today.join(event) }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Reminders

struct NotchRemindersPage: View {
    @ObservedObject var reminders: NotchReminders

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            content(now: context.date)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(.horizontal, AgentComposer.panelInset)
        .padding(.bottom, NotchHome.Card.bottom)
        .onAppear { reminders.refresh() }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        switch reminders.access {
        case .notDetermined:
            VStack(alignment: .leading, spacing: 8) {
                Text("See what's left to do")
                    .font(.app(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                NotchChip(title: String(localized: "Allow Reminders"), prominent: true) { reminders.requestAccess() }
            }
        case .denied:
            VStack(alignment: .leading, spacing: 8) {
                Text("Reminders access is off")
                    .font(.app(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                NotchChip(title: String(localized: "Open Settings")) {
                    if let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Reminders")
                    {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        case .granted:
            if reminders.items.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(red: 0.42, green: 0.86, blue: 0.56))
                    Text("All done")
                        .font(.app(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                }
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(reminders.items) { item in
                        NotchReminderRow(item: item, now: now) { reminders.complete(item.id) }
                    }
                }
            }
        }
    }
}

/// A reminder: a ring to tick, its title, and when it is due.
private struct NotchReminderRow: View {
    let item: NotchReminders.Item
    let now: Date
    let onComplete: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onComplete) {
                Image(systemName: hovered ? "checkmark.circle" : "circle")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(item.color)
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityLabel(Text("Complete \(item.title)"))
            Text(verbatim: item.title)
                .font(.app(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let when = NotchReminders.when(item, now: now) {
                Text(verbatim: when)
                    .font(.app(size: 11))
                    .foregroundStyle(
                        item.due.map { $0 < now } == true ? Color(red: 1, green: 0.45, blue: 0.4) : .white.opacity(0.45)
                    )
            }
        }
        .frame(height: 22)
    }
}

// MARK: - Shelf

struct NotchShelfPage: View {
    @ObservedObject var shelf: NotchShelf
    let dropping: Bool
    /// Tiles that fit beside the clear button; the rest are counted.
    static let visible = 5
    /// The file whose details are open; nothing is read about a file until it is clicked.
    @State private var selected: NotchShelf.Item.ID?

    var body: some View {
        Group {
            if shelf.items.isEmpty || dropping {
                dropArea
            } else if let item = shelf.items.first(where: { $0.id == selected }) {
                NotchShelfDetail(item: item, shelf: shelf) { selected = nil }
                    .frame(maxHeight: .infinity)
            } else {
                // No sideways scrolling: a sideways swipe turns the page.
                HStack(alignment: .center, spacing: 6) {
                    ForEach(shelf.items.prefix(Self.visible)) { item in
                        NotchShelfTile(item: item) { selected = item.id }
                    }
                    if shelf.items.count > Self.visible {
                        Text(verbatim: "+\(shelf.items.count - Self.visible)")
                            .font(.app(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                            .frame(width: 34)
                    }
                    Spacer(minLength: 0)
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

/// A file on the shelf: its icon and name. Click for its details and AirDrop; drag it out to
/// use it, and it stays on the shelf.
private struct NotchShelfTile: View {
    let item: NotchShelf.Item
    let onSelect: () -> Void
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
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: onSelect)
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .help(item.name)
        .accessibilityAddTraits(.isButton)
    }
}

/// One file, opened from its tile: what it is, and what to do with it — AirDrop it, open it,
/// show it in Finder, or take it off the shelf.
private struct NotchShelfDetail: View {
    let item: NotchShelf.Item
    let shelf: NotchShelf
    let onClose: () -> Void
    @State private var details: NotchShelf.Details?

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NotchShelf.icon(for: item))
                .resizable()
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: item.name)
                    .font(.app(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let details {
                    Text(verbatim: details.summary)
                        .font(.app(size: 11))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Text(verbatim: String(localized: "Added \(item.added.formatted(date: .omitted, time: .shortened))"))
                    .font(.app(size: 11))
                    .foregroundStyle(.white.opacity(0.35))
            }
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                NotchServiceButton(service: NSSharingService(named: .sendViaAirDrop), label: "AirDrop") {
                    shelf.airDrop(item.url)
                }
                NotchRoundButton(symbol: "arrow.up.forward.app", label: "Open") { NSWorkspace.shared.open(item.url) }
                NotchRoundButton(symbol: "doc.on.doc", label: "Copy the file") { shelf.copy(item) }
                NotchRoundButton(symbol: "doc.zipper", label: "Compress to a zip") { shelf.compress(item) }
                NotchRoundButton(symbol: "folder", label: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
                NotchRoundButton(symbol: "trash", label: "Remove from the shelf") {
                    shelf.remove(item.id)
                    onClose()
                }
                NotchRoundButton(symbol: "xmark", label: "Back to the shelf", action: onClose)
            }
        }
        .task(id: item.id) { details = NotchShelf.details(of: item) }
    }
}

/// A round button showing a system sharing service's own icon, so AirDrop looks like AirDrop.
private struct NotchServiceButton: View {
    let service: NSSharingService?
    let label: LocalizedStringKey
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if let image = service?.image {
                    Image(nsImage: image).resizable().frame(width: 18, height: 18)
                } else {
                    Image(systemName: "square.and.arrow.up").font(.system(size: 12, weight: .semibold))
                }
            }
            .frame(width: 32, height: 32)
            .background(Circle().fill(.white.opacity(hovered ? 0.16 : 0.09)))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(service == nil)
        .onHover { hovered = $0 }
        .accessibilityLabel(Text(label))
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

// MARK: - Sound

/// Each app that is playing, with its own volume under the system's.
struct NotchSoundPage: View {
    @ObservedObject var mixer: NotchMixer

    var body: some View {
        Group {
            if mixer.apps.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "speaker.wave.2")
                        .font(.system(size: 18, weight: .medium))
                    Text("Apps that are playing show here, each with its own volume")
                        .font(.app(size: 12))
                }
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // No sideways scrolling: a sideways swipe turns the page.
                ScrollView(.vertical) {
                    VStack(spacing: 10) {
                        ForEach(mixer.apps) { app in
                            NotchAppVolumeRow(app: app) { mixer.setGain($0, for: app.bundleID) }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .scrollIndicators(.automatic)
            }
        }
        .padding(.horizontal, AgentComposer.panelInset)
        .padding(.bottom, NotchHome.Card.bottom)
        .onAppear { mixer.setVisible(true) }
        .onDisappear { mixer.setVisible(false) }
    }
}

private struct NotchAppVolumeRow: View {
    let app: NotchMixer.App
    let onChange: (Float) -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let icon = NotchHomeApp.icon(for: app.bundleID) {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            }
            Text(verbatim: app.name)
                .font(.app(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
            Slider(value: Binding(get: { Double(app.gain) }, set: { onChange(Float($0)) }), in: 0...1)
                .controlSize(.small)
                .tint(.white)
            Text(verbatim: "\(Int((app.gain * 100).rounded()))%")
                .font(.appMono(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 36, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(app.name) volume"))
    }
}

// MARK: - Mirror

/// The camera as a mirror, only after a click and only while this page is open.
struct NotchMirrorPage: View {
    @ObservedObject var mirror: NotchMirror

    var body: some View {
        Group {
            switch mirror.state {
            case .on:
                NotchMirrorPreview(session: mirror.session)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.top, 4)
            case .starting:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .off, .denied, .noCamera:
                VStack(spacing: 8) {
                    Text(message)
                        .font(.app(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                    if mirror.state == .denied {
                        NotchChip(title: String(localized: "Open Settings")) {
                            if let url = URL(
                                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
                            {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    } else if mirror.state == .off {
                        NotchChip(title: String(localized: "Show the camera"), prominent: true) { mirror.start() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, AgentComposer.panelInset)
        .padding(.bottom, NotchHome.Card.bottom)
        // Leaving the page, or the card closing, turns the camera off.
        .onDisappear { mirror.stop() }
    }

    private var message: String {
        switch mirror.state {
        case .denied: return String(localized: "Camera access is off")
        case .noCamera: return String(localized: "No camera found")
        default: return String(localized: "A mirror, before a call. The camera stays off until you ask.")
        }
    }
}
