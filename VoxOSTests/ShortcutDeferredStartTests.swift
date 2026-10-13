import Foundation
import Testing

@testable import VoxOS

/// With fn as the shortcut, every fn+key combo used to start a recording on the press and
/// cancel it on the next key: mic, selection read and screen OCR for nothing, and a notch
/// flash. The start now waits a moment. These pin down the three outcomes of that wait.
@MainActor
struct ShortcutDeferredStartTests {

    @MainActor private final class Harness {
        var visible = false
        var state: RecordingState = .idle
        var toggles = 0
        var cancels = 0
        var handsFreeStarts = 0
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
            onHandsFreeRecordingStarted: { [unowned self] in self.handsFreeStarts += 1 },
            startDelay: 0.05
        )
    }

    @Test func aComboNeverStartsARecording() async throws {
        let h = Harness()
        await h.handler.handleKeyDown(action: .primaryRecording, eventTime: 10, mode: .hybrid)
        #expect(h.toggles == 0, "nothing starts on the press itself")
        await h.handler.handleInterruption(action: .primaryRecording)
        try await Task.sleep(for: .milliseconds(120))
        #expect(h.toggles == 0, "the combo dropped the pending start")
        #expect(h.cancels == 0, "nothing had started, so nothing to cancel")
    }

    @Test func aTapStartsHandsFreeAtOnce() async {
        let h = Harness()
        await h.handler.handleKeyDown(action: .primaryRecording, eventTime: 10, mode: .hybrid)
        await h.handler.handleKeyUp(action: .primaryRecording, eventTime: 10.02, mode: .hybrid)
        #expect(h.toggles == 1)
        #expect(h.handsFreeStarts == 1)
        #expect(h.visible)
    }

    @Test func aHoldStartsWhenTheWindowEndsAndStopsOnRelease() async throws {
        let h = Harness()
        await h.handler.handleKeyDown(action: .primaryRecording, eventTime: 10, mode: .hybrid)
        #expect(h.toggles == 0)
        try await Task.sleep(for: .milliseconds(120))
        #expect(h.toggles == 1, "push-to-talk started once the window passed")
        await h.handler.handleKeyUp(action: .primaryRecording, eventTime: 10.8, mode: .hybrid)
        #expect(h.toggles == 2, "a long hold stops on release")
        #expect(h.handsFreeStarts == 0)
    }

    @Test func toggleModeTapStartsHandsFreeToo() async {
        let h = Harness()
        await h.handler.handleKeyDown(action: .primaryRecording, eventTime: 10, mode: .toggle)
        await h.handler.handleKeyUp(action: .primaryRecording, eventTime: 10.03, mode: .toggle)
        #expect(h.toggles == 1)
        #expect(h.handsFreeStarts == 1)
    }

    @Test func pushToTalkIsUnchanged() async {
        let h = Harness()
        await h.handler.handleKeyDown(action: .primaryRecording, eventTime: 10, mode: .pushToTalk)
        #expect(h.toggles == 1, "push-to-talk still starts on the press")
    }

    @Test func zeroDelayKeepsTheImmediateStart() async {
        let h = Harness()
        let immediate = RecordingShortcutModeHandler(
            canHandleShortcutAction: { true }, isRecorderVisible: { h.visible }, recordingState: { h.state },
            toggleRecorderPanel: { _ in h.toggles += 1 }, cancelRecording: {})
        await immediate.handleKeyDown(action: .primaryRecording, eventTime: 10, mode: .hybrid)
        #expect(h.toggles == 1)
    }
}
