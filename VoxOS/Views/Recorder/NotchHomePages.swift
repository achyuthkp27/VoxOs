import AppKit
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

    /// Music only while there is a track; the rest always.
    static func available(hasTrack: Bool) -> [NotchHomePage] {
        hasTrack ? allCases : allCases.filter { $0 != .music }
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
    /// The timer, its settings, or one setting being changed. Back to the timer whenever the page
    /// goes away, since the view goes with it.
    @State private var panel: Panel = .timer
    /// What START begins: a focus session or either break, picked under the time.
    @State private var startKind: NotchTimer.Kind = .focus

    enum Panel: Equatable {
        case timer
        case settings(SettingsTab)
        case edit(Setting)
    }

    enum SettingsTab: Equatable {
        case duration
        case notifications
    }

    enum Setting: CaseIterable, Equatable {
        case focus
        case shortBreak
        case longBreak
        case sessions
    }

    static let ringSize: CGFloat = 148
    static let buttonSize: CGFloat = 34

    /// The card's height on this page: the ring, and the buttons under it.
    static var cardHeight: CGFloat {
        let content: CGFloat = ringSize + 10 + buttonSize
        return NotchHome.Card.top + content + NotchHome.Card.bottom + 6
    }

    var body: some View {
        Group {
            switch panel {
            case .timer: timerPanel
            case .settings(let tab): settingsPanel(tab)
            case .edit(let setting): editPanel(setting)
            }
        }
        .padding(.top, NotchHome.Card.top)
        .padding(.horizontal, AgentComposer.panelInset + 6)
        .padding(.bottom, NotchHome.Card.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Timer

    private var timerPanel: some View {
        NotchTicking(every: 1, while: timers.running != nil) { context in timerFace(at: context.date) }
    }

    private func timerFace(at now: Date) -> some View {
        let running = timers.running
        let kind = running?.kind ?? startKind
        return VStack(spacing: 10) {
            ZStack {
                NotchPomodoroRing(progress: running?.progress(at: now) ?? 0, kind: kind)
                VStack(spacing: 5) {
                    Image(systemName: Self.symbol(for: kind))
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(verbatim: Self.clock(running?.remaining(at: now) ?? timers.durations.length(of: startKind)))
                        .font(.app(size: 38, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(countsDown: true))
                    if kind.isPomodoro { sessionMarks(running) }
                    if running == nil {
                        kindMenu
                    } else {
                        Text(verbatim: caption(running))
                            .font(.app(size: 9, weight: .medium))
                            .tracking(1.2)
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                .frame(width: Self.ringSize - 24)
            }
            .frame(width: Self.ringSize, height: Self.ringSize)
            .contextMenu {
                // Any session can be started at any time, whatever is running.
                ForEach(Self.startable, id: \.self) { kind in
                    Button("Start \(Self.name(of: kind))") { timers.startPomodoro(kind) }
                }
                if running != nil {
                    Divider()
                    Button("Skip to the Next Session") { timers.skip() }
                }
            }
            HStack(spacing: 0) {
                NotchOutlineButton(symbol: "arrow.uturn.backward", label: "Reset") { timers.cancel() }
                    .opacity(running == nil ? 0.35 : 1)
                    .disabled(running == nil)
                Spacer(minLength: 0)
                NotchPillButton(title: pillTitle(running)) {
                    if let running {
                        if running.isPaused { timers.resume() } else { timers.pause() }
                    } else {
                        timers.startPomodoro(startKind)
                    }
                }
                Spacer(minLength: 0)
                NotchOutlineButton(symbol: "gearshape", label: "Pomodoro Settings") {
                    panel = .settings(.duration)
                }
            }
            .frame(width: Self.ringSize + 132, height: Self.buttonSize)
        }
        .frame(maxWidth: .infinity)
    }

    /// One mark per focus session before the long break: those done and the one under way lit.
    private func sessionMarks(_ running: NotchTimer?) -> some View {
        let total = timers.durations.focusesBeforeLongBreak
        let lit = Self.litSessions(running, total: total)
        return HStack(spacing: 5) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(index < lit ? NotchPomodoroRing.accent : .white.opacity(0.25))
                    .frame(width: 3, height: 8)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(lit) of \(total) sessions"))
    }

    /// Sessions to light: those finished in this round, and the focus under way; all of them on the
    /// long break, which closes the round.
    nonisolated static func litSessions(_ running: NotchTimer?, total: Int) -> Int {
        guard let running, total > 0 else { return 0 }
        switch running.kind {
        case .countdown: return 0
        case .longBreak: return total
        case .shortBreak: return running.completedFocus % total
        case .focus: return running.completedFocus % total + 1
        }
    }

    /// The sessions START can begin.
    nonisolated static let startable: [NotchTimer.Kind] = [.focus, .shortBreak, .longBreak]

    nonisolated static func name(of kind: NotchTimer.Kind) -> String {
        switch kind {
        case .shortBreak: return String(localized: "Short Break")
        case .longBreak: return String(localized: "Long Break")
        default: return String(localized: "Focus")
        }
    }

    /// The caption under the time while nothing runs: a click moves what START begins on to the
    /// next session (Focus, Short Break, Long Break), drawn as the caption itself.
    private var kindMenu: some View {
        Button {
            let index = Self.startable.firstIndex(of: startKind) ?? 0
            startKind = Self.startable[(index + 1) % Self.startable.count]
        } label: {
            HStack(spacing: 3) {
                Text(verbatim: Self.name(of: startKind).uppercased())
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 6, weight: .bold))
            }
            .font(.app(size: 9, weight: .medium))
            .tracking(1.2)
            .foregroundStyle(.white.opacity(0.5))
            .lineLimit(1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text("Choose what Start begins"))
        .accessibilityLabel(Text("Start begins \(Self.name(of: startKind)); click for the next"))
    }

    private func caption(_ running: NotchTimer?) -> String {
        switch running?.kind ?? .focus {
        case .focus: return String(localized: "FOCUS")
        case .shortBreak: return String(localized: "SHORT BREAK")
        case .longBreak: return String(localized: "LONG BREAK")
        case .countdown:
            return (running?.label.isEmpty ?? true) ? String(localized: "TIMER") : running!.label.uppercased()
        }
    }

    private func pillTitle(_ running: NotchTimer?) -> LocalizedStringKey {
        guard let running else { return "START" }
        return running.isPaused ? "RESUME" : "PAUSE"
    }

    nonisolated static func symbol(for kind: NotchTimer.Kind) -> String {
        switch kind {
        case .focus: return "eye"
        case .shortBreak: return "cup.and.saucer"
        case .longBreak: return "cup.and.saucer.fill"
        case .countdown: return "timer"
        }
    }

    /// "25:00", "05:00": minutes always two digits, as a timer face reads.
    nonisolated static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        guard total < 3600 else { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: Settings

    private func settingsPanel(_ tab: SettingsTab) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Text("Settings")
                    .font(.app(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                HStack {
                    Spacer()
                    NotchOutlineButton(symbol: "xmark", label: "Close Settings", size: 28) { panel = .timer }
                }
            }
            .frame(height: 30)
            HStack(spacing: 2) {
                tabButton("DURATION", selected: tab == .duration) { panel = .settings(.duration) }
                tabButton("NOTIFICATIONS", selected: tab == .notifications) { panel = .settings(.notifications) }
            }
            .padding(2)
            .background(Capsule().fill(.white.opacity(0.08)))
            Group {
                switch tab {
                case .duration:
                    VStack(spacing: 2) {
                        ForEach(Setting.allCases, id: \.self) { setting in settingRow(setting) }
                    }
                case .notifications:
                    VStack(spacing: 6) {
                        optionRow("Sound When a Session Ends", isOn: $timers.options.sound)
                        optionRow("Start Breaks on Their Own", isOn: $timers.options.startsBreaksOnTheirOwn)
                        optionRow("Start Focus on Its Own After a Break", isOn: $timers.options.startsFocusOnItsOwn)
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: 360)
        }
    }

    private func tabButton(_ title: LocalizedStringKey, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.app(size: 10, weight: .medium))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(selected ? 0.95 : 0.55))
                .frame(width: 120, height: 24)
                .background(Capsule().fill(.white.opacity(selected ? 0.16 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func settingRow(_ setting: Setting) -> some View {
        Button {
            panel = .edit(setting)
        } label: {
            HStack(spacing: 6) {
                Text(Self.title(of: setting))
                    .font(.app(size: 12))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 8)
                Text(verbatim: Self.figure(value(of: setting), for: setting))
                    .font(.app(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                Text(Self.unit(of: setting))
                    .opacity(setting == .sessions && value(of: setting) == 0 ? 0 : 1)
                    .font(.app(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 30, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A label on the left and its switch on the right, lined up with the Duration rows.
    private func optionRow(_ title: LocalizedStringKey, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.app(size: 12))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 8)
            Toggle(isOn: isOn) { Text(title) }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(NotchPomodoroRing.accent)
        }
        .frame(height: 22)
    }

    // MARK: One setting

    private func editPanel(_ setting: Setting) -> some View {
        let range = Self.range(of: setting)
        let current = value(of: setting)
        return VStack(spacing: 8) {
            HStack {
                NotchOutlineButton(symbol: "chevron.left", label: "Back", size: 28) { panel = .settings(.duration) }
                Spacer()
            }
            .frame(height: 30)
            Text(Self.title(of: setting))
                .font(.app(size: 15, weight: .medium))
                .foregroundStyle(.white)
            HStack(spacing: 24) {
                NotchStepButton(symbol: "minus", label: "Less") { set(setting, to: current - 1) }
                    .disabled(current <= range.lowerBound)
                Text(verbatim: Self.figure(current, for: setting))
                    .font(.app(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .frame(minWidth: 64)
                    .contentTransition(.numericText())
                NotchStepButton(symbol: "plus", label: "More") { set(setting, to: current + 1) }
                    .disabled(current >= range.upperBound)
            }
            Text(setting == .sessions && current == 0 ? "no long break" : Self.unit(of: setting))
                .font(.app(size: 12))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func value(of setting: Setting) -> Int {
        let durations = timers.durations
        switch setting {
        case .focus: return Int((durations.focus / 60).rounded())
        case .shortBreak: return Int((durations.shortBreak / 60).rounded())
        case .longBreak: return Int((durations.longBreak / 60).rounded())
        case .sessions: return durations.focusesBeforeLongBreak
        }
    }

    private func set(_ setting: Setting, to value: Int) {
        let range = Self.range(of: setting)
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        var durations = timers.durations
        switch setting {
        case .focus: durations.focus = TimeInterval(clamped * 60)
        case .shortBreak: durations.shortBreak = TimeInterval(clamped * 60)
        case .longBreak: durations.longBreak = TimeInterval(clamped * 60)
        case .sessions: durations.focusesBeforeLongBreak = clamped
        }
        withAnimation(.snappy) { timers.durations = durations }
    }

    nonisolated static func range(of setting: Setting) -> ClosedRange<Int> {
        switch setting {
        case .focus: return NotchTimers.PomodoroDurations.focusMinutes
        case .shortBreak: return NotchTimers.PomodoroDurations.shortBreakMinutes
        case .longBreak: return NotchTimers.PomodoroDurations.longBreakMinutes
        case .sessions: return NotchTimers.PomodoroDurations.sessions
        }
    }

    private static func title(of setting: Setting) -> LocalizedStringKey {
        switch setting {
        case .focus: return "Focus Session"
        case .shortBreak: return "Short Break"
        case .longBreak: return "Long Break"
        case .sessions: return "Long Break After"
        }
    }

    /// "25", "05", or "Off" for no long break.
    nonisolated static func figure(_ value: Int, for setting: Setting) -> String {
        setting == .sessions && value == 0 ? String(localized: "Off") : String(format: "%02d", value)
    }

    private static func unit(of setting: Setting) -> LocalizedStringKey {
        setting == .sessions ? "sess." : "min"
    }
}

/// The pomodoro's progress: a grey track, and the time gone as an arc in VoxOS's own violet,
/// running from a cool periwinkle through the brand colour to magenta clockwise from the top,
/// glowing a little. A plain timer draws in white.
struct NotchPomodoroRing: View {
    let progress: Double
    let kind: NotchTimer.Kind
    var lineWidth: CGFloat = 7

    static let accent = AppTheme.Accent.brand
    /// The arc's start: the brand colour's lighter, bluer neighbour.
    static let lead = Color(red: 0.42, green: 0.58, blue: 1)
    /// The arc's end, toward magenta.
    static let tail = Color(red: 0.82, green: 0.38, blue: 0.94)

    var body: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.16), lineWidth: lineWidth)
            if progress > 0 {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(fill, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: (kind == .countdown ? Color.white : Self.accent).opacity(0.45), radius: 6)
            }
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
    }

    private var fill: AnyShapeStyle {
        guard kind != .countdown else { return AnyShapeStyle(Color.white) }
        return AnyShapeStyle(
            AngularGradient(
                colors: [Self.lead, Self.accent, Self.tail], center: .center, startAngle: .degrees(0),
                endAngle: .degrees(360 * max(progress, 0.01))))
    }
}

/// A round outlined button, as on the timer's face.
private struct NotchOutlineButton: View {
    let symbol: String
    let label: LocalizedStringKey
    var size: CGFloat = NotchTimerPage.buttonSize
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .medium))
                .foregroundStyle(.white.opacity(hovered ? 1 : 0.8))
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(hovered ? 0.1 : 0.03)))
                .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }
}

/// The capsule under the ring: Start, Pause or Resume.
private struct NotchPillButton: View {
    let title: LocalizedStringKey
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.app(size: 11, weight: .semibold))
                .tracking(1)
                .foregroundStyle(.white.opacity(0.92))
                .frame(width: 112, height: NotchTimerPage.buttonSize)
                .background(Capsule().fill(.white.opacity(hovered ? 0.22 : 0.14)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// − and + beside a setting's number.
private struct NotchStepButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(isEnabled ? 0.9 : 0.3))
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(hovered ? 0.1 : 0))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(
                        .white.opacity(isEnabled ? 0.5 : 0.2), lineWidth: 1.2)
                )
                .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .buttonRepeatBehavior(.enabled)
        .onHover { hovered = $0 }
        .accessibilityLabel(Text(label))
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
        case .focus: return NotchPomodoroRing.accent
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
    @ObservedObject var reminders: NotchReminders

    /// Events and reminders in view at once; the column scrolls to the rest.
    static let visibleEvents = 3
    static let visibleReminders = 3

    /// The card's height on this page: three events, and three reminders under them.
    static var cardHeight: CGFloat {
        let events: CGFloat = CGFloat(visibleEvents) * 26 + CGFloat(visibleEvents - 1) * 9
        let list: CGFloat = CGFloat(visibleReminders) * 22 + CGFloat(visibleReminders - 1) * 7
        return NotchHome.Card.top + 6 + events + 21 + list + NotchHome.Card.bottom + 10
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack(alignment: .center, spacing: 22) {
                dateAndWeather(now: context.date)
                    .frame(width: 128, alignment: .leading)
                Rectangle().fill(.white.opacity(0.08)).frame(width: 1).frame(maxHeight: .infinity)
                    .padding(.vertical, 10)
                // However many there are: the column scrolls, the card keeps its height.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) {
                        events(now: context.date)
                        Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                        NotchRemindersList(reminders: reminders, now: context.date)
                    }
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, AgentComposer.panelInset)
        .padding(.bottom, NotchHome.Card.bottom)
        .onAppear {
            today.refresh()
            reminders.refresh()
        }
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

/// The reminders on the Calendar page, under the events: a ring to tick each one.
private struct NotchRemindersList: View {
    @ObservedObject var reminders: NotchReminders
    let now: Date

    var body: some View {
        content(now: now)
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

/// One page for the extras, so they do not each take a page: each playing app's volume, the
/// clipboard and the camera mirror (each when switched on in Settings), with keeping the Mac
/// awake and pinning the card in its corner.
struct NotchSoundPage: View {
    enum Section: String, CaseIterable, Identifiable {
        case apps
        case clipboard
        case mirror

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .apps: return "square.grid.2x2"
            case .clipboard: return "doc.on.clipboard"
            case .mirror: return "person.crop.square"
            }
        }

        var label: LocalizedStringKey {
            switch self {
            case .apps: return "App volumes"
            case .clipboard: return "Clipboard"
            case .mirror: return "Mirror"
            }
        }
    }

    @ObservedObject var mixer: NotchMixer
    @ObservedObject var clipboard: NotchClipboard
    @ObservedObject var mirror: NotchMirror
    @ObservedObject var keepAwake: NotchKeepAwake
    let pinned: Bool
    let onPin: () -> Void
    /// Whether the mirror is the part shown, for the card's height.
    var onMirrorShown: (Bool) -> Void = { _ in }
    @State private var section: Section?
    @AppStorage(DefaultsKeys.notchMixerEnabled) private var appsOn = true
    @AppStorage(DefaultsKeys.notchClipboardEnabled) private var clipboardOn = false
    @AppStorage(DefaultsKeys.notchMirrorEnabled) private var mirrorOn = true

    private var sections: [Section] {
        Section.allCases.filter { section in
            switch section {
            case .apps: return appsOn
            case .clipboard: return clipboardOn
            case .mirror: return mirrorOn
            }
        }
    }

    private var shown: Section? { section.flatMap { sections.contains($0) ? $0 : nil } ?? sections.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(sections) { item in
                    NotchSegmentButton(symbol: item.symbol, label: item.label, selected: item == shown) {
                        section = item
                    }
                }
                Spacer(minLength: 6)
                NotchToggleChip(
                    symbol: keepAwake.isOn ? "cup.and.saucer.fill" : "cup.and.saucer", on: keepAwake.isOn,
                    tint: .orange,
                    help: keepAwake.isOn ? "Keeping the Mac awake. Click to let it sleep." : "Keep the Mac awake"
                ) { keepAwake.toggle() }
                NotchToggleChip(
                    symbol: pinned ? "pin.fill" : "pin", on: pinned, tint: AppTheme.Accent.primary,
                    help: pinned ? "Unpin: close when the pointer leaves" : "Pin: keep the card open", action: onPin)
            }
            .frame(height: 22)

            Group {
                switch shown {
                case .apps: apps
                case .clipboard: clipboardList
                case .mirror: mirrorView
                case nil:
                    Text("Switch on app volumes, the clipboard or the mirror in Settings → Notch Home")
                        .font(.app(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.top, 2)
        .padding(.horizontal, AgentComposer.panelInset)
        .padding(.bottom, NotchHome.Card.bottom)
        .onAppear {
            mixer.setVisible(shown == .apps)
            onMirrorShown(shown == .mirror)
        }
        .onChange(of: shown) { old, new in
            mixer.setVisible(new == .apps)
            if old == .mirror { mirror.stop() }
            onMirrorShown(new == .mirror)
        }
        // Leaving the page, or the card closing, stops the camera and the app list's listening.
        .onDisappear {
            mixer.setVisible(false)
            mirror.stop()
            onMirrorShown(false)
        }
    }

    // MARK: Apps

    @ViewBuilder
    private var apps: some View {
        if mixer.apps.isEmpty {
            NotchPageHint(symbol: "speaker.wave.2", text: "Apps that are playing show here, each with its own volume")
        } else {
            ScrollView(.vertical) {
                VStack(spacing: 8) {
                    ForEach(mixer.apps) { app in
                        NotchAppVolumeRow(app: app) { mixer.setGain($0, for: app.bundleID) }
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
    }

    // MARK: Clipboard

    @ViewBuilder
    private var clipboardList: some View {
        if clipboard.items.isEmpty {
            NotchPageHint(symbol: "doc.on.clipboard", text: "Text you copy shows here, to copy again")
        } else {
            ScrollView(.vertical) {
                VStack(spacing: 4) {
                    ForEach(clipboard.items) { item in
                        NotchClipboardRow(item: item) { clipboard.copy(item) }
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
    }

    // MARK: Mirror

    @ViewBuilder
    private var mirrorView: some View {
        switch mirror.state {
        case .on:
            NotchMirrorPreview(layer: mirror.previewLayer)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .starting:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .off:
            VStack(spacing: 6) {
                Text("A mirror, before a call. The camera stays off until you ask.")
                    .font(.app(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                NotchChip(title: String(localized: "Show the camera"), prominent: true) { mirror.start() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .denied:
            VStack(spacing: 6) {
                Text("Camera access is off").font(.app(size: 11)).foregroundStyle(.white.opacity(0.5))
                NotchChip(title: String(localized: "Open Settings")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noCamera:
            NotchPageHint(symbol: "video.slash", text: "No camera found")
        }
    }
}

/// An icon, and a line under it, for a part of a page with nothing in it yet.
private struct NotchPageHint: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
            Text(text).font(.app(size: 11))
        }
        .foregroundStyle(.white.opacity(0.45))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A part of the Sound page, chosen by its icon.
private struct NotchSegmentButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(selected ? 1 : hovered ? 0.85 : 0.55))
                .frame(width: 30, height: 20)
                .background(Capsule().fill(.white.opacity(selected ? 0.18 : hovered ? 0.1 : 0.05)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(Text(label))
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Keep awake or pin: lit in its colour while on.
private struct NotchToggleChip: View {
    let symbol: String
    let on: Bool
    let tint: Color
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(on ? tint : .white.opacity(hovered ? 0.95 : 0.6))
                .frame(width: 24, height: 20)
                .background(Capsule().fill(.white.opacity(hovered || on ? 0.14 : 0.06)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

private struct NotchClipboardRow: View {
    let item: NotchClipboard.Item
    let action: () -> Void
    @State private var copied = false

    var body: some View {
        Button {
            action()
            copied = true
        } label: {
            HStack(spacing: 10) {
                Text(verbatim: item.text.replacingOccurrences(of: "\n", with: " "))
                    .font(.app(size: 12))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(copied ? "Copied" : item.at.formatted(.relative(presentation: .named)))
                    .font(.app(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.text)
    }
}

private struct NotchAppVolumeRow: View {
    let app: NotchMixer.App
    let onChange: (Float) -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let icon = NotchHomeApp.icon(for: app.bundleID) {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
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
