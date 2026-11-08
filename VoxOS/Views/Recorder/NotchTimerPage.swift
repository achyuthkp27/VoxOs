import AppKit
import CoreAudio
import SwiftUI
import UniformTypeIdentifiers

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
