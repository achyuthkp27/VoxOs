import Carbon.HIToolbox
import Foundation
import Testing

@testable import VoxOS

/// Key (non-modifier-only) shortcuts in the shared tap: which events the tap may swallow, and
/// what a re-registration does to a shortcut that is physically held at the time.
@MainActor
struct ShortcutMonitorKeyShortcutTests {

    private static let optionR = Shortcut.key(keyCode: UInt16(kVK_ANSI_R), modifierFlags: [.option])

    /// The handlers hop to main asynchronously; let them land before asserting.
    private func drainMain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func releasingTheModifierEndsTheShortcutWithoutSwallowingTheFlagsChange() async {
        let monitor = ShortcutMonitor()
        let events = EventLog()
        monitor.configureForTesting(
            shortcuts: [.primaryRecording: Self.optionR],
            onKeyDown: { action, _ in events.append("down \(action.storageName)") },
            onKeyUp: { action, _ in events.append("up \(action.storageName)") })

        let downSuppressed = monitor.feed(.keyDown, keyCode: UInt16(kVK_ANSI_R), flags: [.option], at: 1.0)
        #expect(downSuppressed, "the shortcut's own key-down is ours")

        // Another modifier joining does not end the shortcut, and the event is not ours either.
        let shiftDown = monitor.feed(.flagsChanged, keyCode: UInt16(kVK_Shift), flags: [.option, .shift], at: 1.1)
        #expect(!shiftDown)

        // ⌥ up while R is still down: the shortcut ends, but the frontmost app must see ⌥ go up.
        let optionUp = monitor.feed(.flagsChanged, keyCode: UInt16(kVK_Option), flags: [.shift], at: 1.5)
        #expect(!optionUp, "a flagsChanged event is never suppressed")

        // The key's own release afterwards matches nothing and passes through.
        let keyUp = monitor.feed(.keyUp, keyCode: UInt16(kVK_ANSI_R), flags: [], at: 1.6)
        #expect(!keyUp)

        await drainMain()
        #expect(events.items == ["down primaryRecording", "up primaryRecording"])
    }

    @Test func theShortcutsOwnKeyUpIsStillSuppressed() async {
        let monitor = ShortcutMonitor()
        monitor.configureForTesting(
            shortcuts: [.primaryRecording: Self.optionR], onKeyDown: { _, _ in }, onKeyUp: { _, _ in })

        monitor.feed(.keyDown, keyCode: UInt16(kVK_ANSI_R), flags: [.option], at: 1.0)
        let keyUp = monitor.feed(.keyUp, keyCode: UInt16(kVK_ANSI_R), flags: [.option], at: 1.3)
        #expect(keyUp, "the key the shortcut is bound to belongs to the shortcut, down and up")
    }

    @Test func reregisteringAnUnchangedShortcutKeepsThePress() async {
        let monitor = ShortcutMonitor()
        monitor.simulatesEventTapInstallFailure = true
        monitor.retryScheduler = { _, _ in }
        let events = EventLog()
        func register() {
            monitor.register(
                owner: .recording,
                shortcuts: [.primaryRecording: Self.optionR],
                onKeyDown: { action, _ in events.append("down \(action.storageName)") },
                onKeyUp: { action, _ in events.append("up \(action.storageName)") })
        }

        register()
        monitor.feed(.keyDown, keyCode: UInt16(kVK_ANSI_R), flags: [.option], at: 1.0)
        // A settings change rebuilds the registration while R is still held.
        register()
        monitor.feed(.keyUp, keyCode: UInt16(kVK_ANSI_R), flags: [.option], at: 1.5)
        // The next press must not be swallowed.
        monitor.feed(.keyDown, keyCode: UInt16(kVK_ANSI_R), flags: [.option], at: 2.0)
        monitor.feed(.keyUp, keyCode: UInt16(kVK_ANSI_R), flags: [.option], at: 2.2)

        await drainMain()
        #expect(
            events.items == [
                "down primaryRecording", "up primaryRecording", "down primaryRecording", "up primaryRecording",
            ])
        monitor.unregister(owner: .recording)
    }

    @Test func reregisteringAChangedShortcutReleasesTheHeldOne() async {
        let monitor = ShortcutMonitor()
        monitor.simulatesEventTapInstallFailure = true
        monitor.retryScheduler = { _, _ in }
        let events = EventLog()
        func register(_ shortcut: Shortcut) {
            monitor.register(
                owner: .recording,
                shortcuts: [.primaryRecording: shortcut],
                onKeyDown: { action, _ in events.append("down \(action.storageName)") },
                onKeyUp: { action, _ in events.append("up \(action.storageName)") })
        }

        register(Self.optionR)
        monitor.feed(.keyDown, keyCode: UInt16(kVK_ANSI_R), flags: [.option], at: 1.0)
        // The user picks a different key while the old one is held: the handler must hear a
        // release, or it keeps waiting for one that can never come.
        register(.key(keyCode: UInt16(kVK_ANSI_T), modifierFlags: [.option]))

        await drainMain()
        #expect(events.items == ["down primaryRecording", "up primaryRecording"])
        monitor.unregister(owner: .recording)
    }
}
