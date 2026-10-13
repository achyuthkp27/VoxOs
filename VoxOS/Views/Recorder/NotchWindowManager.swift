import AppKit
import Combine
import SwiftUI
import os

@MainActor
class NotchWindowManager {
    private var windowController: NSWindowController?
    private var panel: NotchRecorderPanel?
    private var outsideClickMonitor: Any?
    private var followUpFocusCancellable: AnyCancellable?
    /// The band's size as last laid out by the view. Zero until the view has reported it.
    private var pillSize: CGSize = .zero {
        didSet { publishVisibleRegion() }
    }
    /// The screen metrics the hosted view was built for; `show()` rebuilds when they change.
    private var builtMetrics: NotchRecorderPanel.WindowMetrics?

    private let makeView: ((width: CGFloat, height: CGFloat), @escaping (CGSize) -> Void) -> AnyView
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
        self.makeView = { metrics, onPillSizeChange in
            AnyView(
                NotchRecorderView(
                    stateProvider: engine,
                    recorder: recorder,
                    assistantSession: assistantSession,
                    onRecordButtonTapped: onRecordButtonTapped,
                    onCloseTapped: onCloseTapped,
                    onAssistantFollowUp: onAssistantFollowUp,
                    notchMetrics: metrics,
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
    ///
    /// `screen` places the band on that screen, as when the idle tab on it is clicked; nil uses
    /// the usual screen (see RecorderScreenResolver).
    @discardableResult
    func show(on screen: NSScreen? = nil) -> Bool {
        // The notch width and height are handed to the SwiftUI view once, when the window is
        // built, while `panel.show()` moves the window to whichever screen holds the key window.
        // A window built for the notched built-in display and shown on an external one kept the
        // built-in notch's silhouette, so rebuild whenever the target screen's metrics differ.
        if panel == nil
            || Self.needsRebuild(built: builtMetrics, current: NotchRecorderPanel.calculateWindowMetrics(on: screen))
        {
            initializeWindow(on: screen)
        }
        guard let panel else { return false }
        let shown = panel.show(on: screen)
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
    /// liveness test and no panel is carried across dictations. The caller waits for the band's
    /// close animation before calling this (see RecorderUIManager.hideRecorderPanelAfterCollapse).
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
            // The window is far larger than the band and transparent around it, so a click
            // there reaches the app behind. Only the band itself counts as inside.
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

    /// A click this close to the band's edge still counts as a click on the band.
    static let outsideClickTolerance: CGFloat = 6

    /// A window built for one set of screen metrics must not be shown with another. With no
    /// current screen there is nothing to rebuild for; `panel.show()` reports that case itself.
    static func needsRebuild(
        built: NotchRecorderPanel.WindowMetrics?, current: NotchRecorderPanel.WindowMetrics?
    ) -> Bool {
        guard let built, let current else { return false }
        return built.frame != current.frame || built.notchWidth != current.notchWidth
            || built.notchHeight != current.notchHeight
    }

    /// The band hangs from the top of the window, centred on it (see NotchRecorderView.body).
    static func pillRect(size: CGSize, in panelFrame: NSRect) -> NSRect {
        NSRect(
            x: panelFrame.midX - size.width / 2, y: panelFrame.maxY - size.height, width: size.width,
            height: size.height)
    }

    /// Tells AgentSelfGuard which part of this window is the band, so the pointer over the
    /// transparent rest of the window is not mistaken for a pointer over VoxOS.
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
    private func initializeWindow(on screen: NSScreen?) {
        deinitializeWindow()
        guard let metrics = NotchRecorderPanel.calculateWindowMetrics(on: screen) else {
            logger.error("Notch panel not created: no screen available")
            return
        }
        let newPanel = NotchRecorderPanel(contentRect: metrics.frame)
        builtMetrics = metrics
        pillSize = .zero
        let view = makeView((width: metrics.notchWidth, height: metrics.notchHeight)) { [weak self] size in
            self?.pillSize = size
        }
        let hostingController = NotchRecorderHostingController(rootView: view)
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
        builtMetrics = nil
    }

}
