import Foundation
import Testing

@testable import VoxOS

/// Timers in the notch: a countdown ends once and chimes once, a pomodoro walks focus → break →
/// focus with a long break every fourth focus, and a running timer survives a relaunch.
@Suite
@MainActor
struct NotchTimersTests {
    private final class Chimes {
        var count = 0
    }

    private func make(_ suite: String = UUID().uuidString) -> (NotchTimers, Chimes, UserDefaults) {
        let defaults = UserDefaults(suiteName: "NotchTimersTests.\(suite)")!
        let chimes = Chimes()
        return (NotchTimers(defaults: defaults, chime: { chimes.count += 1 }), chimes, defaults)
    }

    @Test func aCountdownEndsOnceWithItsLabel() {
        let (timers, chimes, _) = make()
        let start = Date()
        timers.startCountdown(minutes: 10, label: "Tea", now: start)
        #expect(timers.running?.remaining(at: start.addingTimeInterval(60)) == 540)

        timers.advance(now: start.addingTimeInterval(599))
        #expect(timers.finished == nil)
        timers.advance(now: start.addingTimeInterval(600))
        #expect(timers.finished?.label == "Tea")
        #expect(timers.running == nil, "a countdown has nothing after it")
        timers.advance(now: start.addingTimeInterval(601))
        #expect(chimes.count == 1)

        timers.advance(now: start.addingTimeInterval(600 + NotchTimers.finishedLinger))
        #expect(timers.finished == nil, "the finished card leaves by itself")
    }

    @Test func aPomodoroAlternatesAndTakesALongBreakAfterTheFourthFocus() {
        let (timers, _, _) = make()
        var now = Date()
        timers.startPomodoro(now: now)
        var kinds: [NotchTimer.Kind] = [timers.running!.kind]
        for _ in 0..<8 {
            now = timers.running!.ends
            timers.advance(now: now)
            kinds.append(timers.running!.kind)
        }
        #expect(
            kinds == [
                .focus, .shortBreak, .focus, .shortBreak, .focus, .shortBreak, .focus, .longBreak, .focus,
            ])
    }

    @Test func skipMovesToTheNextPhaseAndCancelClearsEverything() {
        let (timers, _, _) = make()
        timers.startPomodoro()
        timers.skip()
        #expect(timers.running?.kind == .shortBreak)
        timers.cancel()
        #expect(timers.running == nil)
        #expect(timers.finished == nil)
    }

    @Test func aRunningTimerSurvivesARelaunch() {
        let suite = UUID().uuidString
        let (first, _, _) = make(suite)
        first.startCountdown(minutes: 30, label: "Laundry")
        let (second, _, defaults) = make(suite)
        #expect(second.running?.label == "Laundry")
        second.cancel()
        #expect(defaults.data(forKey: "NotchTimerRunning") == nil)
    }

    @Test func clockReadsLikeAClock() {
        #expect(NotchTimers.clock(59.2) == "1:00", "rounds up, so 0:00 only at the end")
        #expect(NotchTimers.clock(25 * 60) == "25:00")
        #expect(NotchTimers.clock(3_725) == "1:02:05")
    }

    /// "Start a pomodoro" by voice has to reach the timer tools, and nothing unrelated should.
    @Test func timerToolsAreOfferedWhenTheRequestIsAboutATimer() {
        #expect(AgentToolCatalog.onDemandSection(for: "start a pomodoro")?.contains("pomodoro_start") == true)
        #expect(AgentToolCatalog.onDemandSection(for: "set a timer for 10 minutes")?.contains("timer_start") == true)
        #expect(AgentToolCatalog.onDemandSection(for: "open Safari") == nil)
        #expect(AgentControlMode.mutatingTools.isSuperset(of: ["timer_start", "pomodoro_start", "timer_cancel"]))
    }

    @Test func pausingHoldsTheTimeLeft() {
        let (timers, chimes, _) = make()
        let start = Date()
        timers.startCountdown(minutes: 1, now: start)
        timers.pause(now: start.addingTimeInterval(20))
        timers.advance(now: start.addingTimeInterval(300))
        #expect(timers.running?.remaining(at: start.addingTimeInterval(300)) == 40, "time stands still")
        #expect(chimes.count == 0)
        timers.resume(now: start.addingTimeInterval(300))
        #expect(timers.running?.ends == start.addingTimeInterval(340))
        timers.advance(now: start.addingTimeInterval(340))
        #expect(chimes.count == 1)
    }
}
