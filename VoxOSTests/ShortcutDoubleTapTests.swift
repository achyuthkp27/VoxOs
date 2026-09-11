import Foundation
import Testing

@testable import VoxOS

/// The recording-shortcut state machine around the fn double-tap: a second tap while the
/// first tap's hands-free recording is running must switch to Agent mode, not stop recording.
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
}
