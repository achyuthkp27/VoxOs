import AppKit
import Combine
import Foundation

/// One countdown at a time, in the notch: a plain timer or a pomodoro.
///
/// A pomodoro runs focus → break → focus…, with a long break after every fourth focus, and moves
/// on by itself. The running timer is stored as an end date, so it survives a relaunch and is
/// never off by however long the app was busy.
struct NotchTimer: Codable, Equatable {
    enum Kind: String, Codable {
        case countdown
        case focus
        case shortBreak
        case longBreak

        var isPomodoro: Bool { self != .countdown }
    }

    var kind: Kind
    var label: String
    var duration: TimeInterval
    var ends: Date
    /// Focus sessions finished in this pomodoro, for the long break.
    var completedFocus: Int = 0
    /// Set while paused: the time that was left. `ends` means nothing meanwhile.
    var pausedRemaining: TimeInterval? = nil

    var isPaused: Bool { pausedRemaining != nil }

    func remaining(at now: Date) -> TimeInterval { pausedRemaining ?? max(0, ends.timeIntervalSince(now)) }

    func progress(at now: Date) -> Double {
        guard duration > 0 else { return 1 }
        return min(1, max(0, 1 - remaining(at: now) / duration))
    }

    /// What follows when this one ends: nothing for a countdown, the next phase for a pomodoro.
    func next(after now: Date, durations: NotchTimers.PomodoroDurations) -> NotchTimer? {
        switch kind {
        case .countdown:
            return nil
        case .focus:
            let done = completedFocus + 1
            // Zero sessions: no long break, a short one after every focus.
            let long = durations.focusesBeforeLongBreak > 0 && done % durations.focusesBeforeLongBreak == 0
            let length = long ? durations.longBreak : durations.shortBreak
            return NotchTimer(
                kind: long ? .longBreak : .shortBreak, label: long ? "Long break" : "Break", duration: length,
                ends: now.addingTimeInterval(length), completedFocus: done)
        case .shortBreak, .longBreak:
            return NotchTimer(
                kind: .focus, label: "Focus", duration: durations.focus, ends: now.addingTimeInterval(durations.focus),
                completedFocus: completedFocus)
        }
    }
}

@MainActor
final class NotchTimers: ObservableObject {
    static let shared = NotchTimers()

    struct PomodoroDurations: Equatable, Codable {
        var focus: TimeInterval = 25 * 60
        var shortBreak: TimeInterval = 5 * 60
        var longBreak: TimeInterval = 15 * 60
        var focusesBeforeLongBreak = 4

        /// What each can be set to on the Pomodoro page, in minutes (sessions for the last, where 0
        /// means never a long break).
        static let focusMinutes = 1...180
        static let shortBreakMinutes = 1...60
        static let longBreakMinutes = 1...90
        static let sessions = 0...12

        /// How long a session of `kind` lasts; a plain countdown has no length of its own here.
        func length(of kind: NotchTimer.Kind) -> TimeInterval {
            switch kind {
            case .focus, .countdown: return focus
            case .shortBreak: return shortBreak
            case .longBreak: return longBreak
            }
        }
    }

    /// How a pomodoro tells you a session ended, and whether the next one waits for you. Off, the
    /// next session is ready, paused at its full length, until you press Start.
    struct PomodoroOptions: Equatable, Codable {
        var sound = true
        /// A break starts by itself when a focus session ends.
        var startsBreaksOnTheirOwn = true
        /// A focus session starts by itself when a break ends.
        var startsFocusOnItsOwn = true
        /// A running pomodoro waits while another app uses the microphone or a camera, and goes
        /// on when the call ends.
        var pausesForCalls = true

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            sound = try values.decodeIfPresent(Bool.self, forKey: .sound) ?? true
            // One switch for both before they were separate: it answers for each until changed.
            let both = try values.decodeIfPresent(Bool.self, forKey: .startsNextOnItsOwn) ?? true
            startsBreaksOnTheirOwn = try values.decodeIfPresent(Bool.self, forKey: .startsBreaksOnTheirOwn) ?? both
            startsFocusOnItsOwn = try values.decodeIfPresent(Bool.self, forKey: .startsFocusOnItsOwn) ?? both
            pausesForCalls = try values.decodeIfPresent(Bool.self, forKey: .pausesForCalls) ?? true
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(sound, forKey: .sound)
            try values.encode(startsBreaksOnTheirOwn, forKey: .startsBreaksOnTheirOwn)
            try values.encode(startsFocusOnItsOwn, forKey: .startsFocusOnItsOwn)
            try values.encode(pausesForCalls, forKey: .pausesForCalls)
        }

        /// Whether the session that follows starts by itself.
        func startsOnItsOwn(_ next: NotchTimer.Kind) -> Bool {
            next == .focus ? startsFocusOnItsOwn : startsBreaksOnTheirOwn
        }

        private enum CodingKeys: String, CodingKey {
            case sound
            case startsNextOnItsOwn
            case startsBreaksOnTheirOwn
            case startsFocusOnItsOwn
            case pausesForCalls
        }
    }

    /// Focus sessions finished today and the time they took; a new day starts at nothing.
    struct FocusLog: Equatable, Codable {
        var day: String
        var sessions = 0
        var seconds: TimeInterval = 0

        /// Today's log, or an empty one when the saved one is from another day.
        func on(_ day: String) -> FocusLog { self.day == day ? self : FocusLog(day: day) }
    }

    /// The finished timer, shown in the notch for a moment.
    struct Finished: Equatable {
        let label: String
        let next: NotchTimer?
        let at: Date
    }

    static let finishedLinger: TimeInterval = 6
    private static let storageKey = "NotchTimerRunning"

    @Published private(set) var running: NotchTimer?
    @Published private(set) var finished: Finished?
    /// Set on the Pomodoro page and kept; a change applies from the next session on.
    @Published var durations = PomodoroDurations() {
        didSet { store(durations, as: Self.durationsKey) }
    }
    @Published var options = PomodoroOptions() {
        didSet { store(options, as: Self.optionsKey) }
    }
    /// Today's finished focus sessions.
    @Published private(set) var focusLog: FocusLog
    /// Paused because a call began, so the call's end may go on with it.
    private(set) var pausedForCall = false
    private static let durationsKey = "NotchPomodoroDurations"
    private static let focusLogKey = "NotchFocusToday"
    private static let optionsKey = "NotchPomodoroOptions"

    private var tick: Timer?
    private let defaults: UserDefaults
    private let chime: () -> Void

    init(defaults: UserDefaults = .standard, chime: @escaping () -> Void = { NSSound(named: "Glass")?.play() }) {
        self.defaults = defaults
        self.chime = chime
        let today = NotchNotes.dayKey(Date())
        focusLog = (Self.load(Self.focusLogKey, from: defaults) ?? FocusLog(day: today)).on(today)
        if let saved: PomodoroDurations = Self.load(Self.durationsKey, from: defaults) { durations = saved }
        if let saved: PomodoroOptions = Self.load(Self.optionsKey, from: defaults) { options = saved }
        if let data = defaults.data(forKey: Self.storageKey),
            let saved = try? JSONDecoder().decode(NotchTimer.self, from: data)
        {
            running = saved
            schedule()
            advance()
        }
    }

    // MARK: Starting and stopping

    func startCountdown(minutes: Double, label: String = "", now: Date = Date()) {
        let seconds = max(1, minutes * 60)
        start(NotchTimer(kind: .countdown, label: label, duration: seconds, ends: now.addingTimeInterval(seconds)))
    }

    /// Starts a pomodoro with the session asked for, a focus or either break; it carries on from
    /// there as usual.
    func startPomodoro(_ kind: NotchTimer.Kind = .focus, now: Date = Date()) {
        let kind: NotchTimer.Kind = kind == .countdown ? .focus : kind
        let length = durations.length(of: kind)
        let label: String
        switch kind {
        case .shortBreak: label = "Break"
        case .longBreak: label = "Long break"
        default: label = "Focus"
        }
        start(NotchTimer(kind: kind, label: label, duration: length, ends: now.addingTimeInterval(length)))
    }

    func cancel() {
        pausedForCall = false
        running = nil
        finished = nil
        save()
        schedule()
    }

    func pause(now: Date = Date()) {
        guard var timer = running, !timer.isPaused else { return }
        timer.pausedRemaining = timer.remaining(at: now)
        running = timer
        save()
    }

    func resume(now: Date = Date()) {
        pausedForCall = false
        guard var timer = running, let left = timer.pausedRemaining else { return }
        timer.ends = now.addingTimeInterval(left)
        timer.pausedRemaining = nil
        running = timer
        save()
    }

    /// Skips to the next pomodoro phase, or ends a countdown early.
    func skip(now: Date = Date()) {
        guard let running else { return }
        self.running = running.next(after: now, durations: durations)
        save()
        schedule()
    }

    // MARK: Calls

    /// A call began: a running pomodoro waits, if that is wanted. A countdown keeps going; it is
    /// a time set for something else.
    func callStarted(now: Date = Date()) {
        guard options.pausesForCalls, let running, running.kind.isPomodoro, !running.isPaused else { return }
        pause(now: now)
        pausedForCall = true
    }

    /// The call ended: the pomodoro it paused goes on. One paused by hand stays paused.
    func callEnded(now: Date = Date()) {
        guard pausedForCall else { return }
        resume(now: now)
    }

    /// Today's count with a focus session of `seconds` added.
    nonisolated static func logged(_ log: FocusLog, adding seconds: TimeInterval, on day: String) -> FocusLog {
        var log = log.on(day)
        log.sessions += 1
        log.seconds += seconds
        return log
    }

    /// "1 session · 25m today", "4 sessions · 1h 40m today".
    nonisolated static func focusSummary(_ log: FocusLog) -> String {
        let minutes = Int((log.seconds / 60).rounded())
        let time = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        return log.sessions == 1
            ? String(localized: "1 session · \(time) today")
            : String(localized: "\(log.sessions) sessions · \(time) today")
    }

    private func start(_ timer: NotchTimer) {
        pausedForCall = false
        running = timer
        finished = nil
        save()
        schedule()
    }

    // MARK: Time passing

    /// Called every second while something runs; also callable from tests with a chosen `now`.
    func advance(now: Date = Date()) {
        if let finished, now.timeIntervalSince(finished.at) >= Self.finishedLinger { self.finished = nil }
        guard let running, !running.isPaused, running.remaining(at: now) <= 0 else { return }
        var next = running.next(after: now, durations: durations)
        if let kind = next?.kind, !options.startsOnItsOwn(kind), let length = next?.duration {
            next?.pausedRemaining = length
        }
        if running.kind == .focus {
            focusLog = Self.logged(focusLog, adding: running.duration, on: NotchNotes.dayKey(now))
            store(focusLog, as: Self.focusLogKey)
        }
        finished = Finished(label: label(for: running), next: next, at: now)
        self.running = next
        if options.sound { chime() }
        save()
        schedule()
    }

    private func store<Value: Encodable>(_ value: Value, as key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<Value: Decodable>(_ key: String, from defaults: UserDefaults) -> Value? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }

    private func label(for timer: NotchTimer) -> String {
        switch timer.kind {
        case .countdown: return timer.label.isEmpty ? String(localized: "Time's up") : timer.label
        case .focus: return String(localized: "Focus done")
        case .shortBreak, .longBreak: return String(localized: "Break over")
        }
    }

    private func schedule() {
        let needsTick = running != nil || finished != nil
        if needsTick, tick == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.advance() }
            }
            RunLoop.main.add(timer, forMode: .common)
            tick = timer
        } else if !needsTick {
            tick?.invalidate()
            tick = nil
        }
    }

    private func save() {
        if let running, let data = try? JSONEncoder().encode(running) {
            defaults.set(data, forKey: Self.storageKey)
        } else {
            defaults.removeObject(forKey: Self.storageKey)
        }
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
