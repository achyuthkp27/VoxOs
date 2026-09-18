import Carbon.HIToolbox
import XCTest

@testable import VoxOS

/// A failed `tapCreate` used to be permanent for the life of the process. At launch the tap is
/// built before Accessibility is trusted, so it fails, and macOS never calls back when the grant
/// lands. `RecordingShortcutManager` hid that by rebuilding its monitor on any shortcut or
/// setting change; `ModeShortcutManager` only rebuilds when a mode shortcut itself changes, so a
/// launch-time failure left every mode shortcut dead for the whole session.
final class ShortcutMonitorRetryTests: XCTestCase {
    private var shortcuts: [ShortcutAction: Shortcut] {
        [
            .mode(UUID()): .modifierOnly(
                keyCode: UInt16(kVK_RightOption),
                modifierFlags: [.option]
            )
        ]
    }

    func testFailedInstallRetriesWithExponentialBackoff() {
        let monitor = ShortcutMonitor()
        monitor.simulatesEventTapInstallFailure = true

        var delays: [TimeInterval] = []
        var pendingRetries: [() -> Void] = []
        monitor.retryScheduler = { delay, work in
            delays.append(delay)
            pendingRetries.append(work)
        }

        monitor.start(shortcuts: shortcuts, onKeyDown: { _, _ in }, onKeyUp: { _, _ in })

        XCTAssertEqual(delays, [1], "a failed install must schedule a retry rather than give up")

        pendingRetries.removeFirst()()
        pendingRetries.removeFirst()()

        XCTAssertEqual(delays, [1, 2, 4], "each failed retry should back off")

        monitor.stop()
    }

    func testBackoffIsCappedSoRetriesStayCheap() {
        let monitor = ShortcutMonitor()
        monitor.simulatesEventTapInstallFailure = true

        var delays: [TimeInterval] = []
        var pendingRetries: [() -> Void] = []
        monitor.retryScheduler = { delay, work in
            delays.append(delay)
            pendingRetries.append(work)
        }

        monitor.start(shortcuts: shortcuts, onKeyDown: { _, _ in }, onKeyUp: { _, _ in })

        // Each retry consumes one pending closure and schedules exactly one more, so the queue
        // never grows — drive a fixed number of rounds instead of waiting for it to fill.
        for _ in 0..<12 {
            guard !pendingRetries.isEmpty else { break }
            pendingRetries.removeFirst()()
        }

        XCTAssertEqual(delays.last, 30, "backoff must settle at the cap, not grow without bound")

        monitor.stop()
    }

    func testStopCancelsAPendingRetry() {
        let monitor = ShortcutMonitor()
        monitor.simulatesEventTapInstallFailure = true

        var delays: [TimeInterval] = []
        var pendingRetries: [() -> Void] = []
        monitor.retryScheduler = { delay, work in
            delays.append(delay)
            pendingRetries.append(work)
        }

        monitor.start(shortcuts: shortcuts, onKeyDown: { _, _ in }, onKeyUp: { _, _ in })
        XCTAssertEqual(pendingRetries.count, 1)

        monitor.stop()
        pendingRetries.removeFirst()()

        XCTAssertEqual(delays, [1], "a retry left over from a stopped monitor must not reschedule")
    }

    func testMonitorWithNoShortcutsNeverSchedulesARetry() {
        let monitor = ShortcutMonitor()
        monitor.simulatesEventTapInstallFailure = true

        var delays: [TimeInterval] = []
        monitor.retryScheduler = { delay, _ in delays.append(delay) }

        monitor.start(shortcuts: [:], onKeyDown: { _, _ in }, onKeyUp: { _, _ in })

        XCTAssertTrue(delays.isEmpty, "nothing is registered, so there is nothing to retry for")

        monitor.stop()
    }
}
