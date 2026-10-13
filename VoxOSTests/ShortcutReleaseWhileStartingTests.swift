import Foundation
import Testing

@testable import VoxOS

/// The mic can take longer than the hybrid hold threshold to open. A release that lands while
/// the engine is still `.starting` used to be classed as a tap, turning a push-to-talk hold
/// into a hands-free recording. It is a hold: the recorder is asked to finish.
@MainActor
struct ShortcutReleaseWhileStartingTests {

    @MainActor private final class Harness {
        var visible = false
        var state: RecordingState = .idle
        var toggles = 0
        var handsFreeStarts = 0
        lazy var handler = RecordingShortcutModeHandler(
            canHandleShortcutAction: { true },
            isRecorderVisible: { [unowned self] in self.visible },
            recordingState: { [unowned self] in self.state },
            toggleRecorderPanel: { [unowned self] _ in
                self.toggles += 1
                self.visible.toggle()
                // The start is slow: the panel is up but the engine has not reached .recording.
                self.state = self.visible ? .starting : .idle
            },
            cancelRecording: {},
            onHandsFreeRecordingStarted: { [unowned self] in self.handsFreeStarts += 1 }
        )
    }

    @Test func hybridHoldReleasedWhileStartingFinishesInsteadOfGoingHandsFree() async {
        let h = Harness()
        await h.handler.handleKeyDown(action: .primaryRecording, eventTime: 10.0, mode: .hybrid)
        #expect(h.toggles == 1)
        #expect(h.state == .starting)

        await h.handler.handleKeyUp(action: .primaryRecording, eventTime: 10.8, mode: .hybrid)
        #expect(h.toggles == 2, "a long hold released while starting asks the recorder to finish")
        #expect(h.handsFreeStarts == 0, "…and is not mistaken for a tap")
    }

    @Test func hybridTapReleasedWhileStartingStillGoesHandsFree() async {
        let h = Harness()
        await h.handler.handleKeyDown(action: .primaryRecording, eventTime: 10.0, mode: .hybrid)
        await h.handler.handleKeyUp(action: .primaryRecording, eventTime: 10.1, mode: .hybrid)
        #expect(h.toggles == 1, "a quick tap keeps recording")
        #expect(h.handsFreeStarts == 1)
    }
}
