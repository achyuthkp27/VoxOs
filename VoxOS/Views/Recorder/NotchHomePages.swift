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

/// The Calendar page: the month beside a row of days, the picked one in the middle; under them
/// that day as an agenda — all-day events as chips, timed ones on a time column with their
/// calendar's bar, and the reminders on the same grid.
struct NotchTodayPage: View {
    @ObservedObject var today: NotchToday
    @ObservedObject var reminders: NotchReminders
    /// Told how tall the list is, so the card can fit it.
    var onListHeight: (CGFloat) -> Void = { _ in }

    static let stripHeight: CGFloat = 52
    /// The rule under the strip, with its space above and below.
    static let ruleSpace: CGFloat = 19
    /// The width of the time column, where events start and reminders are due.
    static let timeWidth: CGFloat = 52
    /// The width of the column holding each event's bar and each reminder's ring.
    static let markWidth: CGFloat = 15

    /// The list at its shortest, a single line…
    static var minimumListHeight: CGFloat { 30 }
    /// …and at its tallest; past that it scrolls.
    static var maximumListHeight: CGFloat { 196 }

    /// The card's height on this page: the strip, and the list under it, fitted to what it holds.
    static func cardHeight(list: CGFloat) -> CGFloat {
        let fitted = min(max(list, minimumListHeight), maximumListHeight)
        return NotchHome.Card.top + 4 + stripHeight + ruleSpace + fitted + NotchHome.Card.bottom + 6
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 0) {
                header(now: context.date)
                    .frame(height: Self.stripHeight)
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                    .padding(.top, 9).padding(.bottom, Self.ruleSpace - 10)
                ScrollView(.vertical) {
                    agenda(now: context.date)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height.rounded(.up)
                        } action: { height in
                            onListHeight(height)
                        }
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, AgentComposer.panelInset)
        .padding(.bottom, NotchHome.Card.bottom)
        .onAppear {
            today.refresh()
            reminders.refresh()
        }
    }

    // MARK: Strip

    private func header(now: Date) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                today.select(now)
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: today.selectedDay.formatted(.dateTime.month(.abbreviated)))
                        .font(.app(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                    Text(verbatim: today.selectedDay.formatted(.dateTime.year()))
                        .font(.app(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 58, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Today"))
            .accessibilityLabel(Text("Go to today"))
            NotchWeekStrip(
                selected: today.selectedDay, busy: busyDays, now: now, onSelect: { today.select($0) })
        }
    }

    /// Days with an event or a reminder due.
    private var busyDays: Set<Date> {
        let days = NotchToday.stripDays(around: today.selectedDay)
        return today.busyDays.union(NotchReminders.dueDays(reminders.items, in: days))
    }

    // MARK: Agenda

    @ViewBuilder
    private func agenda(now: Date) -> some View {
        let day = today.selectedDay
        let events = today.calendarAccess == .granted ? today.dayEvents : []
        let allDay = events.filter(\.isAllDay)
        let timed = events.filter { !$0.isAllDay }
        let items = reminders.access == .granted ? NotchReminders.items(reminders.items, on: day, now: now) : []
        VStack(alignment: .leading, spacing: 0) {
            calendarAccessPrompt
            if !allDay.isEmpty {
                NotchAllDayRow(events: allDay)
                    .padding(.bottom, timed.isEmpty ? 0 : 10)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(timed) { event in
                    NotchAgendaEvent(
                        event: event, day: day, now: now, canJoin: NotchToday.canJoin(event, now: now),
                        onJoin: { today.join(event) })
                }
            }
            if !items.isEmpty {
                NotchAgendaSection(title: String(localized: "Reminders"), count: items.count)
                    .padding(.top, events.isEmpty ? 0 : 12)
                    .padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(items) { item in
                        NotchAgendaReminder(item: item, now: now) { reminders.complete(item.id) }
                    }
                }
            }
            remindersAccessPrompt
                .padding(.top, events.isEmpty ? 0 : 12)
            if events.isEmpty, items.isEmpty, today.calendarAccess == .granted, reminders.access == .granted {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(NotchDayCell.accent)
                    (Calendar.current.isDate(day, inSameDayAs: now)
                        ? Text("Nothing planned today") : Text("Nothing planned"))
                        .font(.app(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.leading, Self.timeWidth + 10)
                .frame(height: Self.minimumListHeight, alignment: .center)
            }
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var calendarAccessPrompt: some View {
        switch today.calendarAccess {
        case .notDetermined:
            NotchAccessPrompt(title: String(localized: "See what's on")) {
                NotchChip(title: String(localized: "Allow Calendar"), prominent: true) {
                    today.requestCalendarAccess()
                }
            }
        case .denied:
            NotchAccessPrompt(title: String(localized: "Calendar access is off")) {
                NotchChip(title: String(localized: "Open Settings")) {
                    openPrivacySettings("Privacy_Calendars")
                }
            }
        case .granted:
            EmptyView()
        }
    }

    @ViewBuilder
    private var remindersAccessPrompt: some View {
        switch reminders.access {
        case .notDetermined:
            NotchAccessPrompt(title: String(localized: "See what's left to do")) {
                NotchChip(title: String(localized: "Allow Reminders"), prominent: true) { reminders.requestAccess() }
            }
        case .denied:
            NotchAccessPrompt(title: String(localized: "Reminders access is off")) {
                NotchChip(title: String(localized: "Open Settings")) {
                    openPrivacySettings("Privacy_Reminders")
                }
            }
        case .granted:
            EmptyView()
        }
    }
}

/// The row of days: as many as fit, the selected one in the middle on a filled tile. A click
/// picks a day and the row centres on it; it never scrolls, so a sideways swipe still turns the page.
private struct NotchWeekStrip: View {
    let selected: Date
    let busy: Set<Date>
    let now: Date
    let onSelect: (Date) -> Void

    static let minimumCellWidth: CGFloat = 46

    var body: some View {
        GeometryReader { proxy in
            let count = Self.cellCount(for: proxy.size.width)
            HStack(spacing: 0) {
                ForEach(days(count: count), id: \.self) { day in
                    NotchDayCell(
                        day: day, isSelected: day == selected,
                        isToday: Calendar.current.isDate(day, inSameDayAs: now),
                        isBusy: busy.contains(day)
                    ) { onSelect(day) }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(.snappy(duration: 0.28), value: selected)
        }
    }

    /// An odd number, so one day sits in the middle.
    static func cellCount(for width: CGFloat) -> Int {
        let fit = max(5, Int(width / minimumCellWidth))
        return fit.isMultiple(of: 2) ? fit - 1 : fit
    }

    private func days(count: Int) -> [Date] {
        NotchToday.stripDays(around: selected, reach: min(count / 2, NotchToday.stripReach))
    }
}

/// A day in the row: its weekday over its date, and a dot when something is on. The selected day
/// sits on a filled tile; today, when another day is picked, keeps its date in the accent.
private struct NotchDayCell: View {
    let day: Date
    let isSelected: Bool
    let isToday: Bool
    let isBusy: Bool
    let action: () -> Void
    @State private var hovered = false

    static let accent = Color(nsColor: .systemBlue)

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(verbatim: weekday)
                    .font(.app(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(isSelected ? 1 : 0.4))
                Text(verbatim: day.formatted(.dateTime.day()))
                    .font(.app(size: 17, weight: isSelected ? .bold : .medium, design: .rounded))
                    .foregroundStyle(numberColor)
                Circle()
                    .fill(isSelected ? .white : Self.accent)
                    .frame(width: 4, height: 4)
                    .opacity(isBusy ? 1 : 0)
            }
            .frame(width: 38, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Self.accent : .white.opacity(hovered ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(Text(verbatim: day.formatted(date: .complete, time: .omitted)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The selected day spells out its weekday; the others give a letter.
    private var weekday: String {
        isSelected
            ? day.formatted(.dateTime.weekday(.abbreviated)).uppercased()
            : day.formatted(.dateTime.weekday(.narrow))
    }

    private var numberColor: Color {
        if isSelected { return .white }
        if isToday { return Self.accent }
        if Calendar.current.isDateInWeekend(day) { return Color(red: 1, green: 0.5, blue: 0.5).opacity(0.8) }
        return .white.opacity(0.75)
    }
}

/// All-day events as chips in their calendar's colour, beside the time column's "All day".
private struct NotchAllDayRow: View {
    let events: [NotchToday.Event]
    static let shown = 3

    var body: some View {
        HStack(spacing: 6) {
            Text("All day")
                .textCase(.uppercase)
                .font(.app(size: 9.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: NotchTodayPage.timeWidth, alignment: .trailing)
                .padding(.trailing, 4)
            ForEach(events.prefix(Self.shown)) { event in
                HStack(spacing: 5) {
                    Circle().fill(event.color).frame(width: 6, height: 6)
                    Text(verbatim: event.title)
                        .font(.app(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(event.color.opacity(0.2)))
                .help(Text(verbatim: event.title))
            }
            if events.count > Self.shown {
                Text(verbatim: "+\(events.count - Self.shown)")
                    .font(.app(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

/// A timed event: when it starts and ends, its calendar's bar — filling as it runs — and its title
/// over where it is and how soon.
private struct NotchAgendaEvent: View {
    let event: NotchToday.Event
    let day: Date
    let now: Date
    let canJoin: Bool
    let onJoin: () -> Void

    var body: some View {
        let progress = NotchToday.progress(event, now: now)
        let detail = NotchToday.detail(event, now: now)
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(verbatim: NotchToday.shortTime(event.start, on: day))
                    .font(.app(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(verbatim: NotchToday.shortTime(event.end, on: day))
                    .font(.app(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: NotchTodayPage.timeWidth, alignment: .trailing)
            ZStack(alignment: .top) {
                Capsule().fill(event.color.opacity(progress == nil ? 1 : 0.3))
                if let progress {
                    GeometryReader { proxy in
                        Capsule().fill(event.color).frame(height: max(3, proxy.size.height * progress))
                    }
                }
            }
            .frame(width: 3)
            .frame(width: NotchTodayPage.markWidth)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: event.title)
                        .font(.app(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if progress != nil {
                        Text("Now")
                            .textCase(.uppercase)
                            .font(.app(size: 9, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(height: 15)
                            .background(Capsule().fill(event.color))
                            .fixedSize()
                    }
                }
                if !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(.app(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if canJoin { NotchJoinButton(action: onJoin).padding(.top, 2) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .opacity(event.end <= now ? 0.4 : 1)
    }
}

/// A small header in the agenda: its title, a count, and a rule to the edge.
private struct NotchAgendaSection: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: title.uppercased())
                .font(.app(size: 9.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.4))
            Text(verbatim: "\(count)")
                .font(.app(size: 9.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
        }
    }
}

/// A reminder on the agenda's grid: when it is due in the time column, a ring to tick where the
/// events have their bar, and its title.
private struct NotchAgendaReminder: View {
    let item: NotchReminders.Item
    let now: Date
    let onComplete: () -> Void
    @State private var hovered = false

    var body: some View {
        let overdue = NotchReminders.isOverdue(item, now: now)
        HStack(spacing: 10) {
            Text(verbatim: NotchReminders.dueLabel(item, now: now))
                .font(.app(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(overdue ? Color(red: 1, green: 0.45, blue: 0.4) : .white.opacity(0.4))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: NotchTodayPage.timeWidth, alignment: .trailing)
            Button(action: onComplete) {
                ZStack {
                    Circle().strokeBorder(item.color, lineWidth: 1.5)
                    if hovered {
                        Image(systemName: "checkmark")
                            .font(.system(size: 7, weight: .heavy))
                            .foregroundStyle(item.color)
                    }
                }
                .frame(width: NotchTodayPage.markWidth, height: NotchTodayPage.markWidth)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityLabel(Text("Complete \(item.title)"))
            Text(verbatim: item.title)
                .font(.app(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .help(Text(verbatim: item.title))
            Spacer(minLength: 0)
        }
    }
}

/// Asking for Calendar or Reminders access, from the page itself.
private struct NotchAccessPrompt<Action: View>: View {
    let title: String
    let action: Action

    init(title: String, @ViewBuilder action: () -> Action) {
        self.title = title
        self.action = action()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title)
                .font(.app(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            action
        }
        .padding(.leading, NotchTodayPage.timeWidth + 10)
    }
}

/// Opens a pane of System Settings → Privacy & Security, such as "Privacy_Calendars".
@MainActor
private func openPrivacySettings(_ pane: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Shelf

struct NotchShelfPage: View {
    @ObservedObject var shelf: NotchShelf
    let dropping: Bool
    let pinned: Bool
    let onPin: () -> Void
    /// Tiles that fit beside the clear button; the rest are counted.
    static let visible = 4
    /// The file whose details are open; nothing is read about a file until it is clicked.
    @State private var selected: NotchShelf.Item.ID?

    var body: some View {
        Group {
            if shelf.items.isEmpty || dropping {
                // Two places to drop: the shelf keeps the files, AirDrop sends them on at once.
                HStack(spacing: 8) {
                    dropArea
                    NotchAirDropZone(shelf: shelf, dropping: dropping)
                        .frame(width: 128)
                    NotchRoundButton(
                        symbol: pinned ? "pin.fill" : "pin",
                        label: pinned ? "Unpin: close when the pointer leaves" : "Pin: keep the card open",
                        on: pinned,
                        tint: AppTheme.Accent.primary,
                        action: onPin
                    )
                }
                .padding(.top, 4)
            } else if let item = shelf.items.first(where: { $0.id == selected }) {
                NotchShelfDetail(item: item, shelf: shelf, pinned: pinned, onPin: onPin) { selected = nil }
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
                    NotchRoundButton(
                        symbol: pinned ? "pin.fill" : "pin",
                        label: pinned ? "Unpin: close when the pointer leaves" : "Pin: keep the card open",
                        on: pinned,
                        tint: AppTheme.Accent.primary,
                        action: onPin
                    )
                    NotchServiceButton(
                        service: NSSharingService(named: .sendViaAirDrop), label: "AirDrop everything on the shelf"
                    ) {
                        shelf.airDrop(shelf.items.map(\.url))
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

    /// The shelf's half looks idle while files are held over the AirDrop zone.
    private var keeping: Bool { dropping && !shelf.airDropTargeted }

    private var dropArea: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
                .white.opacity(keeping ? 0.6 : 0.2), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])
            )
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(keeping ? 0.08 : 0.02))
            )
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: keeping ? "tray.and.arrow.down.fill" : "tray")
                        .font(.system(size: 20, weight: .medium))
                    Text(keeping ? "Drop to keep it here" : "Drop files here to keep them")
                        .font(.app(size: 12))
                }
                .foregroundStyle(.white.opacity(keeping ? 0.9 : 0.45))
            }
    }
}

/// Files dropped here go straight to AirDrop. The zone tells the shelf where it is, so the card
/// can send a drop here rather than onto the shelf.
private struct NotchAirDropZone: View {
    @ObservedObject var shelf: NotchShelf
    let dropping: Bool

    private static let service = NSSharingService(named: .sendViaAirDrop)

    var body: some View {
        let hot = shelf.airDropTargeted
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
                hot ? Color(nsColor: .systemBlue) : .white.opacity(0.2),
                style: StrokeStyle(lineWidth: 1.2, dash: hot ? [] : [5, 4])
            )
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hot ? Color(nsColor: .systemBlue).opacity(0.18) : .white.opacity(0.02))
            )
            .overlay {
                VStack(spacing: 6) {
                    if let image = Self.service?.image {
                        Image(nsImage: image).resizable().frame(width: 26, height: 26)
                    } else {
                        Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 20, weight: .medium))
                    }
                    Text(hot ? "Drop to AirDrop" : "AirDrop")
                        .font(.app(size: 12, weight: hot ? .semibold : .regular))
                }
                .foregroundStyle(.white.opacity(hot ? 0.95 : 0.45))
            }
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named(NotchHome.cardSpace))
            } action: { frame in
                shelf.airDropZone = frame
            }
            .onDisappear { shelf.airDropZone = nil }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text("Drop files here to AirDrop them"))
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
        .onDrag { NotchShelf.itemProvider(for: item) }
        .help(item.name)
        .accessibilityAddTraits(.isButton)
    }
}

/// One file, opened from its tile: what it is, and what to do with it — AirDrop it, open it,
/// show it in Finder, or take it off the shelf.
private struct NotchShelfDetail: View {
    let item: NotchShelf.Item
    let shelf: NotchShelf
    let pinned: Bool
    let onPin: () -> Void
    let onClose: () -> Void
    @State private var details: NotchShelf.Details?

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NotchShelf.icon(for: item))
                .resizable()
                .frame(width: 52, height: 52)
                .onDrag { NotchShelf.itemProvider(for: item) }
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
                NotchRoundButton(
                    symbol: pinned ? "pin.fill" : "pin",
                    label: pinned ? "Unpin: close when the pointer leaves" : "Pin: keep the card open",
                    on: pinned,
                    tint: AppTheme.Accent.primary,
                    action: onPin
                )
                NotchServiceButton(service: NSSharingService(named: .sendViaAirDrop), label: "AirDrop") {
                    shelf.airDrop([item.url])
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
    var on: Bool = false
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? (tint ?? AppTheme.Accent.primary) : .white.opacity(hovered ? 1 : 0.75))
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(
                        on
                            ? (tint ?? AppTheme.Accent.primary).opacity(hovered ? 0.3 : 0.18)
                            : .white.opacity(hovered ? 0.16 : 0.09)
                    )
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(label)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(on ? .isSelected : [])
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
