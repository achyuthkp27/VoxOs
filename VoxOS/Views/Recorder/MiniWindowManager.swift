import AppKit
import Combine
import SwiftUI
import os

@MainActor
class MiniWindowManager {
    private var windowController: NSWindowController?
    private var panel: MiniRecorderPanel?
    private var outsideClickMonitor: Any?
    private var followUpFocusCancellable: AnyCancellable?
    /// The pill's size as last laid out by the view. Zero until the view has reported it.
    private var pillSize: CGSize = .zero {
        didSet { publishVisibleRegion() }
    }

    private let makeView: (@escaping (CGSize) -> Void) -> AnyView
    private let onCloseTapped: () -> Void
    private weak var assistantSession: AssistantSession?
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "MiniWindowManager")

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
        self.makeView = { onPillSizeChange in
            AnyView(
                MiniRecorderView(
                    stateProvider: engine,
                    recorder: recorder,
                    assistantSession: assistantSession,
                    onRecordButtonTapped: onRecordButtonTapped,
                    onCloseTapped: onCloseTapped,
                    onAssistantFollowUp: onAssistantFollowUp,
                    onPillSizeChange: onPillSizeChange
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
        if shown {
            publishVisibleRegion()
            installOutsideClickMonitor()
            focusPanelWhenFollowUpBecomesAvailable()
        }
        return shown
    }

    /// The panel can become key but is only ordered front, so keystrokes kept going to the app
    /// behind it and the follow-up field's focus request did nothing until the user clicked.
    /// Taking key status only once a follow-up can be typed keeps plain dictation from stealing
    /// focus from the paste target; the panel is non-activating, so the front app stays active.
    private func focusPanelWhenFollowUpBecomesAvailable() {
        followUpFocusCancellable?.cancel()
        guard let assistantSession else { return }
        followUpFocusCancellable = assistantSession.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let panel = self.panel, panel.isVisible,
                    self.assistantSession?.canSendFollowUp == true, !panel.isKeyWindow
                else { return }
                panel.makeKey()
            }
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
    /// the explicit close button. Only fires for the idle assistant response state, never while
    /// actively recording, transcribing, or waiting on a reply.
    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self, let panel = self.panel else { return }
            guard let assistantSession = self.assistantSession,
                assistantSession.isVisible,
                !assistantSession.isBusy
            else { return }
            let clickLocation = NSEvent.mouseLocation
            // The window is far larger than the pill and transparent around it, so a click
            // there reaches the app behind. Only the pill itself counts as inside.
            let hitRect =
                self.pillSize == .zero
                ? panel.frame
                : Self.pillRect(size: self.pillSize, in: panel.frame).insetBy(
                    dx: -Self.outsideClickTolerance, dy: -Self.outsideClickTolerance)
            guard !hitRect.contains(clickLocation) else { return }
            Task { @MainActor in
                self.onCloseTapped()
            }
        }
    }

    /// A click this close to the pill's edge still counts as a click on the pill.
    static let outsideClickTolerance: CGFloat = 6

    /// The pill sits at the bottom of the window, centred on it (see MiniRecorderView.body).
    static func pillRect(size: CGSize, in panelFrame: NSRect) -> NSRect {
        NSRect(x: panelFrame.midX - size.width / 2, y: panelFrame.minY, width: size.width, height: size.height)
    }

    /// Tells AgentSelfGuard which part of this window is the pill, so the pointer over the
    /// transparent rest of the window is not mistaken for a pointer over VoxOS. The region is
    /// measured from the window's corner, so it stays right when the pill is dragged.
    private func publishVisibleRegion() {
        guard let panel else { return }
        let region =
            pillSize == .zero
            ? nil : AgentSelfGuard.region(of: Self.pillRect(size: pillSize, in: panel.frame), inWindow: panel.frame)
        AgentSelfGuard.setVisibleRegion(region, ofWindowNumber: panel.windowNumber)
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
        guard let metrics = MiniRecorderPanel.calculateWindowMetrics() else {
            logger.error("Mini panel not created: no screen available")
            return
        }
        let newPanel = MiniRecorderPanel(contentRect: metrics)
        pillSize = .zero
        let view = makeView { [weak self] size in
            self?.pillSize = size
        }
        let hostingController = NSHostingController(rootView: view)
        newPanel.contentView = hostingController.view
        panel = newPanel
        windowController = NSWindowController(window: newPanel)
    }

    private func deinitializeWindow() {
        followUpFocusCancellable?.cancel()
        followUpFocusCancellable = nil
        removeOutsideClickMonitor()
        if let panel { AgentSelfGuard.setVisibleRegion(nil, ofWindowNumber: panel.windowNumber) }
        panel?.orderOut(nil)
        windowController?.close()
        windowController = nil
        panel = nil
    }
}
