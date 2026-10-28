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
            let long = done % durations.focusesBeforeLongBreak == 0
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

    struct PomodoroDurations: Equatable {
        var focus: TimeInterval = 25 * 60
        var shortBreak: TimeInterval = 5 * 60
        var longBreak: TimeInterval = 15 * 60
        var focusesBeforeLongBreak = 4
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
    var durations = PomodoroDurations()

    private var tick: Timer?
    private let defaults: UserDefaults
    private let chime: () -> Void

    init(defaults: UserDefaults = .standard, chime: @escaping () -> Void = { NSSound(named: "Glass")?.play() }) {
        self.defaults = defaults
        self.chime = chime
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

    func startPomodoro(now: Date = Date()) {
        start(
            NotchTimer(
                kind: .focus, label: "Focus", duration: durations.focus, ends: now.addingTimeInterval(durations.focus)))
    }

    func cancel() {
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

    private func start(_ timer: NotchTimer) {
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
        let next = running.next(after: now, durations: durations)
        finished = Finished(label: label(for: running), next: next, at: now)
        self.running = next
        chime()
        save()
        schedule()
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
