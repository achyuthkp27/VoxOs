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

        monitor.register(owner: .testing, shortcuts: shortcuts, onKeyDown: { _, _ in }, onKeyUp: { _, _ in })

        XCTAssertEqual(delays, [1], "a failed install must schedule a retry rather than give up")

        pendingRetries.removeFirst()()
        pendingRetries.removeFirst()()

        XCTAssertEqual(delays, [1, 2, 4], "each failed retry should back off")

        monitor.unregister(owner: .testing)
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

        monitor.register(owner: .testing, shortcuts: shortcuts, onKeyDown: { _, _ in }, onKeyUp: { _, _ in })

        // Each retry consumes one pending closure and schedules exactly one more, so the queue
        // never grows — drive a fixed number of rounds instead of waiting for it to fill.
        for _ in 0..<12 {
            guard !pendingRetries.isEmpty else { break }
            pendingRetries.removeFirst()()
        }

        XCTAssertEqual(delays.last, 30, "backoff must settle at the cap, not grow without bound")

        monitor.unregister(owner: .testing)
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

        monitor.register(owner: .testing, shortcuts: shortcuts, onKeyDown: { _, _ in }, onKeyUp: { _, _ in })
        XCTAssertEqual(pendingRetries.count, 1)

        monitor.unregister(owner: .testing)
        pendingRetries.removeFirst()()

        XCTAssertEqual(delays, [1], "a retry left over from a stopped monitor must not reschedule")
    }

    func testMonitorWithNoShortcutsNeverSchedulesARetry() {
        let monitor = ShortcutMonitor()
        monitor.simulatesEventTapInstallFailure = true

        var delays: [TimeInterval] = []
        monitor.retryScheduler = { delay, _ in delays.append(delay) }

        monitor.register(owner: .testing, shortcuts: [:], onKeyDown: { _, _ in }, onKeyUp: { _, _ in })

        XCTAssertTrue(delays.isEmpty, "nothing is registered, so there is nothing to retry for")

        monitor.unregister(owner: .testing)
    }
}

/// One tap now serves recording, mode and recorder-panel shortcuts. The recorder panel
/// re-registers on every dictation, so a re-registration must never disturb a live tap — that
/// churn is what used to destroy and rebuild a tap the whole system's keyboard ran through.
final class ShortcutMonitorSharedTapTests: XCTestCase {
    private func shortcut(_ keyCode: Int) -> Shortcut {
        .key(keyCode: UInt16(keyCode), modifierFlags: [.option])
    }

    func testEachOwnerKeepsItsOwnShortcutsAndHandlers() {
        let monitor = ShortcutMonitor()
        monitor.simulatesEventTapInstallFailure = true
        monitor.retryScheduler = { _, _ in }

        var recordingHits: [ShortcutAction] = []
        var panelHits: [ShortcutAction] = []

        monitor.register(
            owner: .recording,
            shortcuts: [.primaryRecording: shortcut(kVK_ANSI_R)],
            onKeyDown: { action, _ in recordingHits.append(action) },
            onKeyUp: { _, _ in }
        )
        monitor.register(
            owner: .recorderPanel,
            shortcuts: [.recorderPanelMode(0): shortcut(kVK_ANSI_1)],
            onKeyDown: { action, _ in panelHits.append(action) },
            onKeyUp: { _, _ in }
        )

        monitor.feed(.keyDown, keyCode: UInt16(kVK_ANSI_R), flags: [.option], at: 1)
        monitor.feed(.keyDown, keyCode: UInt16(kVK_ANSI_1), flags: [.option], at: 2)

        let expectation = expectation(description: "handlers dispatched")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(recordingHits, [.primaryRecording], "recording owner got only its own key")
        XCTAssertEqual(panelHits, [.recorderPanelMode(0)], "panel owner got only its own key")

        monitor.unregister(owner: .recording)
        monitor.unregister(owner: .recorderPanel)
    }

    func testUnregisteringOneOwnerLeavesTheOthersRegistered() {
        let monitor = ShortcutMonitor()
        monitor.simulatesEventTapInstallFailure = true
        monitor.retryScheduler = { _, _ in }

        var recordingHits = 0

        monitor.register(
            owner: .recording,
            shortcuts: [.primaryRecording: shortcut(kVK_ANSI_R)],
            onKeyDown: { _, _ in recordingHits += 1 },
            onKeyUp: { _, _ in }
        )
        monitor.register(
            owner: .recorderPanel,
            shortcuts: [.recorderPanelMode(0): shortcut(kVK_ANSI_1)],
            onKeyDown: { _, _ in },
            onKeyUp: { _, _ in }
        )

        monitor.unregister(owner: .recorderPanel)
        monitor.feed(.keyDown, keyCode: UInt16(kVK_ANSI_R), flags: [.option], at: 1)

        let expectation = expectation(description: "handler dispatched")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(recordingHits, 1, "the panel leaving must not deregister recording")

        monitor.unregister(owner: .recording)
    }

    func testReregisteringNeverTearsTheTapDown() {
        let monitor = ShortcutMonitor()
        monitor.simulatesEventTapInstallFailure = true
        monitor.retryScheduler = { _, _ in }

        var teardowns = 0
        monitor.onEventTapTeardown = { teardowns += 1 }

        // The recorder panel re-registers on every single dictation. The old start() began by
        // calling stop(), so each one destroyed and rebuilt a system-wide tap.
        for _ in 0..<5 {
            monitor.register(
                owner: .recorderPanel,
                shortcuts: [.recorderPanelMode(0): shortcut(kVK_ANSI_1)],
                onKeyDown: { _, _ in },
                onKeyUp: { _, _ in }
            )
        }

        XCTAssertEqual(teardowns, 0, "re-registering must not tear the tap down")

        monitor.unregister(owner: .recorderPanel)
    }
}
