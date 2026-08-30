import AppKit
import SwiftUI
import os

@MainActor
class NotchWindowManager {
    private var windowController: NSWindowController?
    private var panel: NotchRecorderPanel?
    private var outsideClickMonitor: Any?

    private let makeView: () -> AnyView
    private let onCloseTapped: () -> Void
    private weak var assistantSession: AssistantSession?
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "NotchWindowManager")

    init(
        engine: VoxOSEngine,
        recorder: Recorder,
        assistantSession: AssistantSession,
        onRecordButtonTapped: @escaping () -> Void,
        onCloseTapped: @escaping () -> Void,
        onAssistantFollowUp: @escaping (String) -> Void
    ) {
        self.onCloseTapped = onCloseTapped
        self.assistantSession = assistantSession
        self.makeView = {
            AnyView(
                NotchRecorderView(
                    stateProvider: engine,
                    recorder: recorder,
                    assistantSession: assistantSession,
                    onRecordButtonTapped: onRecordButtonTapped,
                    onCloseTapped: onCloseTapped,
                    onAssistantFollowUp: onAssistantFollowUp
                )
            )
        }
    }

    /// Builds a fresh panel whenever one is not already on screen.
    ///
    /// The panel and its hosting view used to be created once and then reused for the whole
    /// lifetime of the app, so a window that stopped rendering — after a sleep/wake cycle, a
    /// display reconfiguration, or any other WindowServer hiccup — kept swallowing every later
    /// `orderFrontRegardless()`, and only relaunching VoxOS brought the recorder back.
    /// A window in that state still reports `isVisible == true` with a sane frame, so there is
    /// nothing reliable to test for from inside the process. Rebuilding unconditionally removes
    /// the question: a stale window can never survive into a second dictation. The cost is one
    /// NSPanel plus one hosting controller per dictation, which is noise next to starting audio
    /// capture and a transcription session in the same code path.
    @discardableResult
    func show() -> Bool {
        if panel == nil { initializeWindow() }
        guard let panel else { return false }
        let shown = panel.show()
        if shown { installOutsideClickMonitor() }
        return shown
    }

    /// Tears the window down rather than just ordering it out, so `isVisible` is never used as a
    /// liveness test and no panel is carried across dictations.
    func hide() {
        deinitializeWindow()
    }

    func destroyWindow() {
        deinitializeWindow()
    }

    /// Dismisses the panel on any click outside its bounds, like a popover, instead of requiring
    /// the explicit close button.
    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self, let panel = self.panel else { return }
            // Only auto-dismiss the idle assistant response panel — never while actively
            // recording, transcribing, or waiting on a reply, so an outside click can't
            // accidentally cancel an in-progress dictation or agent turn.
            guard let assistantSession = self.assistantSession,
                assistantSession.isVisible,
                !assistantSession.isBusy
            else { return }
            let clickLocation = NSEvent.mouseLocation
            guard !panel.frame.contains(clickLocation) else { return }
            Task { @MainActor in
                self.onCloseTapped()
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
    }

    // Rebuilding gives the SwiftUI content a new identity, so view-local state inside it is
    // reset — currently the assistant follow-up draft and its focus. The conversation itself
    // lives in `AssistantSession`, which is owned by the engine and survives.
    private func initializeWindow() {
        deinitializeWindow()
        guard let metrics = NotchRecorderPanel.calculateWindowMetrics() else {
            logger.error("Notch panel not created: no screen available")
            return
        }
        let newPanel = NotchRecorderPanel(contentRect: metrics.frame)
        let view = makeView()
        let hostingController = NotchRecorderHostingController(rootView: view)
        newPanel.contentView = hostingController.view
        panel = newPanel
        windowController = NSWindowController(window: newPanel)
    }

    private func deinitializeWindow() {
        removeOutsideClickMonitor()
        panel?.orderOut(nil)
        windowController?.close()
        windowController = nil
        panel = nil
    }

}
