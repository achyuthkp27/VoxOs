import Foundation
import Testing

@testable import VoxOS

/// The recording-shortcut state machine around the fn double-tap: a second tap while the
/// first tap's hands-free recording is running must switch to Agent mode, not stop recording.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func append(_ item: String) { lock.withLock { storage.append(item) } }
    var items: [String] { lock.withLock { storage } }
}

@MainActor
struct ShortcutDoubleTapTests {

    @MainActor private final class Harness {
        var visible = false
        var state: RecordingState = .idle
        var toggles = 0
        var agentSwitches = 0
        var cancels = 0
        lazy var handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: { true },
            isRecorderVisible: { [unowned self] in self.visible },
            recordingState: { [unowned self] in self.state },
            toggleRecorderPanel: { [unowned self] _ in
                self.toggles += 1
                self.visible.toggle()
                self.state = self.visible ? .recording : .idle
            },
            cancelRecording: { [unowned self] in self.cancels += 1 },
            toggleAgentMode: { [unowned self] in
                self.agentSwitches += 1
                return true
            }
        )
    }

    @Test func doubleTapSwitchesToAgentInsteadOfStopping() async {
        UserDefaults.standard.set(true, forKey: RecordingShortcutModeHandler.doubleTapDefaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: RecordingShortcutModeHandler.doubleTapDefaultsKey) }
        let h = Harness()
        // Tap 1: short press in hybrid mode → hands-free recording.
        await h.handler.handleKeyDown(action: .primaryRecording, eventTime: 10.0, mode: .hybrid)
        await h.handler.handleKeyUp(action: .primaryRecording, eventTime: 10.1, mode: .hybrid)
        #expect(h.toggles == 1)
        #expect(h.state == .recording)

        // Tap 2 inside the window: mode switch, recording keeps going.
        await h.handler.handleKeyDown(action: .primaryRecording, eventTime: 10.3, mode: .hybrid)
        await h.handler.handleKeyUp(action: .primaryRecording, eventTime: 10.4, mode: .hybrid)
        #expect(h.agentSwitches == 1)
        #expect(h.toggles == 1, "double-tap must not stop the recording")
        #expect(h.state == .recording)

        // A later single tap still stops it.
        await h.handler.handleKeyDown(action: .primaryRecording, eventTime: 12.0, mode: .hybrid)
        await h.handler.handleKeyUp(action: .primaryRecording, eventTime: 12.1, mode: .hybrid)
        #expect(h.toggles == 2)
        #expect(h.state == .idle)
    }

    @Test func slowSecondTapIsNotADoubleTap() async {
        let h = Harness()
        await h.handler.handleKeyDown(action: .primaryRecording, eventTime: 10.0, mode: .toggle)
        await h.handler.handleKeyUp(action: .primaryRecording, eventTime: 10.1, mode: .toggle)
        let late = 10.1 + RecordingShortcutModeHandler.doubleTapWindow + 0.1
        await h.handler.handleKeyDown(action: .primaryRecording, eventTime: late, mode: .toggle)
        await h.handler.handleKeyUp(action: .primaryRecording, eventTime: late + 0.1, mode: .toggle)
        #expect(h.agentSwitches == 0)
        #expect(h.toggles == 2, "a slow second tap stops the recording as before")
    }

    @Test func doubleTapOnDifferentShortcutDoesNotCount() async {
        let h = Harness()
        await h.handler.handleKeyDown(action: .primaryRecording, eventTime: 10.0, mode: .toggle)
        await h.handler.handleKeyUp(action: .primaryRecording, eventTime: 10.1, mode: .toggle)
        await h.handler.handleKeyDown(action: .secondaryRecording, eventTime: 10.3, mode: .toggle)
        #expect(h.agentSwitches == 0)
    }

    @Test func modeShortcutsNeverDoubleTap() async {
        let h = Harness()
        let id = UUID()
        await h.handler.handleKeyDown(action: .mode(id), eventTime: 10.0, mode: .toggle, modeId: id)
        await h.handler.handleKeyUp(action: .mode(id), eventTime: 10.1, mode: .toggle, modeId: id)
        await h.handler.handleKeyDown(action: .mode(id), eventTime: 10.3, mode: .toggle, modeId: id)
        #expect(h.agentSwitches == 0)
    }

    @MainActor
    @Test func dictationSendKeyRules() {
        DictationSend.clearOnce()
        let saved = UserDefaults.standard.object(forKey: DictationSend.pressReturnKey)
        defer { saved.map { UserDefaults.standard.set($0, forKey: DictationSend.pressReturnKey) } ?? UserDefaults.standard.removeObject(forKey: DictationSend.pressReturnKey) }
        UserDefaults.standard.set(false, forKey: DictationSend.pressReturnKey)

        #expect(DictationSend.keyForPaste(modeKey: .none) == .none)

        DictationSend.armOnce()
        #expect(DictationSend.keyForPaste(modeKey: .none) == .enter, "fn+⌃ sends once")
        #expect(DictationSend.keyForPaste(modeKey: .none) == .none, "…and only once")

        DictationSend.armOnce(now: Date().addingTimeInterval(-DictationSend.onceLifetime - 1))
        #expect(DictationSend.keyForPaste(modeKey: .none) == .none, "a stale arm from an abandoned recording expires")

        DictationSend.armOnce()
        #expect(DictationSend.keyForPaste(modeKey: .commandEnter) == .commandEnter, "a mode's own key wins")

        UserDefaults.standard.set(true, forKey: DictationSend.pressReturnKey)
        #expect(DictationSend.keyForPaste(modeKey: .none) == .enter)
    }

    @Test func dictateAndSendStartsAndStopsLikePushToTalk() async {
        let h = Harness()
        await h.handler.handleKeyDown(action: .dictateAndSend, eventTime: 20.0, mode: .pushToTalk)
        #expect(h.toggles == 1 && h.state == .recording)
        await h.handler.handleKeyUp(action: .dictateAndSend, eventTime: 22.0, mode: .pushToTalk)
        #expect(h.toggles == 2 && h.state == .idle)
    }

    /// fn then ⌃ pressed, ⌃ then fn released — the order a hand actually makes on a MacBook.
    @Test func fnControlComboDispatchOrder() async {
        let monitor = ShortcutMonitor()
        let events = EventLog()
        monitor.configureForTesting(
            shortcuts: [
                .primaryRecording: RecordingShortcutManager.fnShortcut,
                .dictateAndSend: RecordingShortcutManager.dictateAndSendShortcut,
                .agentDoubleTap: RecordingShortcutManager.agentTapShortcut,
            ],
            onKeyDown: { action, _ in events.append("down \(action.storageName)") },
            onKeyUp: { action, _ in events.append("up \(action.storageName)") })

        monitor.feed(.flagsChanged, keyCode: 63, flags: [.function], at: 1.0)
        monitor.feed(.flagsChanged, keyCode: 59, flags: [.function, .control], at: 1.1)
        monitor.feed(.flagsChanged, keyCode: 59, flags: [.function], at: 3.0)
        monitor.feed(.flagsChanged, keyCode: 63, flags: [], at: 3.1)
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(events.items == ["down primaryRecording", "down dictateAndSend", "up dictateAndSend", "up primaryRecording"])
    }

    /// ⌃ first, then fn: only the combo starts, and releasing either key ends it.
    @Test func controlFnComboDispatchOrder() async {
        let monitor = ShortcutMonitor()
        let events = EventLog()
        monitor.configureForTesting(
            shortcuts: [
                .primaryRecording: RecordingShortcutManager.fnShortcut,
                .dictateAndSend: RecordingShortcutManager.dictateAndSendShortcut,
                .agentDoubleTap: RecordingShortcutManager.agentTapShortcut,
            ],
            onKeyDown: { action, _ in events.append("down \(action.storageName)") },
            onKeyUp: { action, _ in events.append("up \(action.storageName)") })

        monitor.feed(.flagsChanged, keyCode: 59, flags: [.control], at: 1.0)
        monitor.feed(.flagsChanged, keyCode: 63, flags: [.control, .function], at: 1.1)
        monitor.feed(.flagsChanged, keyCode: 63, flags: [.control], at: 3.0)
        monitor.feed(.flagsChanged, keyCode: 59, flags: [], at: 3.1)
        try? await Task.sleep(nanoseconds: 200_000_000)

        #expect(events.items.contains("down dictateAndSend"))
        #expect(events.items.contains("up dictateAndSend"))
        #expect(!events.items.contains("down primaryRecording"))
    }

    /// Handler level: fn (hybrid) starts, fn+⌃ joins, both released — the recording must stop.
    @Test func fnHeldThenComboReleasedStopsRecording() async {
        let h = Harness()
        await h.handler.handleKeyDown(action: .primaryRecording, eventTime: 1.0, mode: .hybrid)
        await h.handler.handleKeyDown(action: .dictateAndSend, eventTime: 1.1, mode: .pushToTalk)
        await h.handler.handleKeyUp(action: .dictateAndSend, eventTime: 3.0, mode: .pushToTalk)
        await h.handler.handleKeyUp(action: .primaryRecording, eventTime: 3.1, mode: .hybrid)
        #expect(h.state == .idle, "releasing fn after a long hold must stop the dictation")
    }

    /// Recorded from a real fn+⌃ release: fn up, then ⌃ alone for ~50ms, then ⌃ up.
    @Test func controlLeftAfterComboIsNotATap() async {
        let monitor = ShortcutMonitor()
        let events = EventLog()
        monitor.configureForTesting(
            shortcuts: [
                .primaryRecording: RecordingShortcutManager.fnShortcut,
                .dictateAndSend: RecordingShortcutManager.dictateAndSendShortcut,
                .agentDoubleTap: RecordingShortcutManager.agentTapShortcut,
            ],
            onKeyDown: { action, time in events.append("down \(action.storageName) \(time)") },
            onKeyUp: { action, time in events.append("up \(action.storageName) \(time)") })
        monitor.feed(.flagsChanged, keyCode: 63, flags: [.function], at: 1.0)
        monitor.feed(.flagsChanged, keyCode: 59, flags: [.function, .control], at: 1.04)
        monitor.feed(.flagsChanged, keyCode: 63, flags: [.control], at: 5.40)
        monitor.feed(.flagsChanged, keyCode: 59, flags: [], at: 5.45)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(events.items.contains("down agentDoubleTap 5.4"), "macOS really does report ⌃ alone here")

        #expect(RecordingShortcutManager.isComboLeftover(tapDownAt: 5.40, comboReleasedAt: 5.40))
        #expect(!RecordingShortcutManager.isComboLeftover(tapDownAt: 6.2, comboReleasedAt: 5.40), "a real tap later still counts")
    }
}
