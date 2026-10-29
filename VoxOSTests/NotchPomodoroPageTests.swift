import Foundation
import Testing

@testable import VoxOS

/// The Pomodoro page's settings and marks, and the height each Notch Home page opens at.
@Suite
@MainActor
struct NotchPomodoroPageTests {

    // MARK: Pomodoro

    private func timers() -> (NotchTimers, UserDefaults) {
        let defaults = UserDefaults(suiteName: "NotchPomodoroPageTests.\(UUID().uuidString)")!
        return (NotchTimers(defaults: defaults, chime: {}), defaults)
    }

    @Test func pomodoroSettingsAreKept() {
        let (timers, defaults) = timers()
        timers.durations.focus = 50 * 60
        timers.durations.focusesBeforeLongBreak = 3
        timers.options.sound = false
        let again = NotchTimers(defaults: defaults, chime: {})
        #expect(again.durations.focus == 50 * 60)
        #expect(again.durations.focusesBeforeLongBreak == 3)
        #expect(again.options.sound == false)
        #expect(again.options.startsNextOnItsOwn)
    }

    @Test func theNextSessionCanWaitToBeStarted() {
        let (timers, _) = timers()
        timers.options.startsNextOnItsOwn = false
        let start = Date()
        timers.startPomodoro(now: start)
        timers.advance(now: start.addingTimeInterval(timers.durations.focus))
        #expect(timers.running?.kind == .shortBreak)
        #expect(timers.running?.isPaused == true)
        #expect(timers.running?.remaining(at: start.addingTimeInterval(9999)) == timers.durations.shortBreak)
    }

    @Test func soundCanBeSwitchedOff() {
        final class Count { var value = 0 }
        let count = Count()
        let defaults = UserDefaults(suiteName: "NotchPomodoroPageTests.\(UUID().uuidString)")!
        let timers = NotchTimers(defaults: defaults, chime: { count.value += 1 })
        timers.options.sound = false
        let start = Date()
        timers.startCountdown(minutes: 1, now: start)
        timers.advance(now: start.addingTimeInterval(60))
        #expect(count.value == 0)
    }

    @Test func theMarksCountTheRound() {
        func timer(_ kind: NotchTimer.Kind, done: Int) -> NotchTimer {
            NotchTimer(kind: kind, label: "", duration: 60, ends: Date(), completedFocus: done)
        }
        #expect(NotchTimerPage.litSessions(nil, total: 4) == 0)
        #expect(NotchTimerPage.litSessions(timer(.focus, done: 0), total: 4) == 1, "the focus under way")
        #expect(NotchTimerPage.litSessions(timer(.shortBreak, done: 2), total: 4) == 2)
        #expect(NotchTimerPage.litSessions(timer(.focus, done: 5), total: 4) == 2, "the second round")
        #expect(NotchTimerPage.litSessions(timer(.longBreak, done: 4), total: 4) == 4)
        #expect(NotchTimerPage.clock(5 * 60) == "05:00")
        #expect(NotchTimerPage.clock(59.2) == "01:00", "rounded up, as a countdown shows it")
        #expect(NotchTimerPage.range(of: .sessions) == 2...8)
    }

    @Test func pagesTakeTheHeightTheyNeed() {
        #expect(NotchHome.Card.height(for: .reminders) == NotchHome.Card.height)
        #expect(NotchHome.Card.height(for: .music, panelOpen: true) > NotchHome.Card.height(for: .music))
        #expect(NotchHome.Card.height(for: .music) == NotchHome.Card.height, "the player keeps its compact card")
        #expect(NotchHome.Card.height(for: .weather) > NotchHome.Card.height)
        #expect(NotchHome.Card.height(for: .timer) > NotchHome.Card.height)
        let tall = NotchHome.size(for: .expanded, notchWidth: 180, notchHeight: 32, cardHeight: 260)
        #expect(tall.height == 292)
    }
}
