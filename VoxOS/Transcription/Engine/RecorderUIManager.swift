import AppKit
import Combine
import Foundation
import SwiftUI
import os

enum RecorderPanelStyle: String, CaseIterable, Identifiable {
    case notch
    case mini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notch:
            return String(localized: "Notch")
        case .mini:
            return String(localized: "Bottom")
        }
    }

    static var stored: RecorderPanelStyle {
        // The notch is the default everywhere; on Macs without one it draws at the menu bar.
        let rawValue =
            UserDefaults.standard.string(forKey: DefaultsKeys.recorderType) ?? RecorderPanelStyle.notch.rawValue
        return RecorderPanelStyle(rawValue: rawValue) ?? .notch
    }
}

@MainActor
protocol RecorderPanelPresenting: AnyObject {
    var isRecorderPanelVisible: Bool { get }
    func dismissRecorderPanel() async
}

@MainActor
class RecorderUIManager: ObservableObject, RecorderPanelPresenting {
    @Published var recorderPanelStyle: RecorderPanelStyle = .stored {
        didSet {
            guard oldValue != recorderPanelStyle else { return }
            rebuildVisiblePanel(previousStyle: oldValue)
            UserDefaults.standard.set(recorderPanelStyle.rawValue, forKey: DefaultsKeys.recorderType)
        }
    }

    var recorderType: String {
        get { recorderPanelStyle.rawValue }
        set { recorderPanelStyle = RecorderPanelStyle(rawValue: newValue) ?? .notch }
    }

    @Published var isRecorderPanelVisible = false {
        didSet {
            guard oldValue != isRecorderPanelVisible else { return }

            if isRecorderPanelVisible {
                showRecorderPanel()
            } else {
                hideRecorderPanelAfterCollapse()
            }
        }
    }

    /// Claude Code's band or approval card is on screen (see ClaudeCodeNotchManager). The idle tab
    /// hides under it, as it does under the recorder.
    @Published var isClaudeCodeSurfaceVisible = false
    /// A Claude Code request, question or offer card in particular: the notch home hides under
    /// it, but takes the place of Claude Code's "working" band.
    @Published var isClaudeCodeCardVisible = false
    /// The notch home's music band or player is on screen (see NotchHomeManager).
    @Published var isNotchHomeVisible = false

    private var notchWindowManager: NotchWindowManager?
    private var miniWindowManager: MiniWindowManager?
    private var idleTabManager: NotchIdleTabManager?
    private var claudeCodeNotchManager: ClaudeCodeNotchManager?
    private var notchHomeManager: NotchHomeManager?
    private var panelInvalidationTask: Task<Void, Never>?
    /// A hide waiting for the band's close animation to finish. A show cancels it.
    private var pendingHideTask: Task<Void, Never>?
    private var didSetupNotifications = false
    private var lifecycleCancellable: AnyCancellable?
    /// The screen this dictation's panel was asked to appear on, such as the idle tab's own
    /// screen when the tab is clicked. Nil means the usual screen (see RecorderScreenResolver).
    /// Kept while the panel is up, so a reposition after a display change stays on it.
    private var requestedScreen: NSScreen?

    private weak var engine: VoxOSEngine?
    private var recorder: Recorder?

    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "RecorderUIManager")

    init() {}

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Call after VoxOSEngine is created to break the circular init dependency.
    func configure(engine: VoxOSEngine, recorder: Recorder) {
        self.engine = engine
        self.recorder = recorder
        setupNotifications()
        if !ProcessIdentity.isTestHost {
            idleTabManager = NotchIdleTabManager(uiManager: self)
            claudeCodeNotchManager = ClaudeCodeNotchManager(uiManager: self)
            notchHomeManager = NotchHomeManager(uiManager: self)
            ClaudeCodeIntegration.shared.startIfEnabled()
        }
    }

    // MARK: - Recorder Panel Management

    private func showRecorderPanel() {
        // A dismissal still waiting for its close animation must not order out the panel this
        // show brings back, and the new recording must not wait for it either.
        pendingHideTask?.cancel()
        pendingHideTask = nil
        guard let engine = engine, let recorder = recorder else { return }

        let shown: Bool

        switch recorderPanelStyle {
        case .notch:
            if notchWindowManager == nil {
                notchWindowManager = NotchWindowManager(
                    engine: engine,
                    recorder: recorder,
                    assistantSession: engine.assistantSession,
                    onRecordButtonTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.toggleRecorderPanel()
                        }
                    },
                    onCloseTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.dismissRecorderPanel()
                        }
                    },
                    onAssistantFollowUp: { [weak engine] text in
                        Task { @MainActor in
                            await engine?.sendAssistantFollowUp(text)
                        }
                    }
                )
            }
            // A screen that has gone away since it was asked for falls back to the usual one.
            let screen = requestedScreen.flatMap { NSScreen.screens.contains($0) ? $0 : nil }
            shown = notchWindowManager?.show(on: screen) ?? false
        case .mini:
            if miniWindowManager == nil {
                miniWindowManager = MiniWindowManager(
                    engine: engine,
                    recorder: recorder,
                    assistantSession: engine.assistantSession,
                    onRecordButtonTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.toggleRecorderPanel()
                        }
                    },
                    onCloseTapped: { [weak self] in
                        Task { @MainActor in
                            await self?.dismissRecorderPanel()
                        }
                    },
                    onAssistantFollowUp: { [weak engine] text in
                        Task { @MainActor in
                            await engine?.sendAssistantFollowUp(text)
                        }
                    }
                )
            }
            shown = miniWindowManager?.show() ?? false
        }

        if shown {
            logger.notice("Showed recorder panel style=\(self.recorderPanelStyle.rawValue, privacy: .public)")
        } else {
            // Only reachable with no screens at all. Recording still works, so the session is
            // left running rather than cancelled, but it runs without any UI — say so loudly,
            // because this is exactly the symptom users report.
            logger.error(
                "Recorder panel could not be shown style=\(self.recorderPanelStyle.rawValue, privacy: .public) screens=\(NSScreen.screens.count, privacy: .public)"
            )
        }
    }

    private func hideRecorderPanel() {
        pendingHideTask?.cancel()
        pendingHideTask = nil
        // `dismissRecorderPanel()` and the flag's observer can both get here for one dismissal,
        // so this deliberately stays at debug level.
        logger.debug("Hiding recorder panel style=\(self.recorderPanelStyle.rawValue, privacy: .public)")
        // Both, not just the current style's: a style change while a hide is pending skips
        // rebuildVisiblePanel (the panel is no longer visible), so the old style's window, its
        // outside-click monitor and its makeKey subscription would otherwise outlive the hide.
        notchWindowManager?.hide()
        miniWindowManager?.hide()
        requestedScreen = nil
    }

    /// How long the current style's collapse takes before its window can go. The Mini pill
    /// springs closed more slowly than the notch band.
    private var collapseDuration: TimeInterval {
        switch recorderPanelStyle {
        case .notch: return NotchDesign.closeDuration
        case .mini: return max(NotchDesign.closeDuration, MiniRecorderMotion.collapseDuration)
        }
    }

    /// Orders the panel out only after the band has had time to play its close animation. The
    /// collapsed state comes from the engine and the assistant session, which the caller has
    /// already reset; ordering out at once cut the animation off every time.
    private func hideRecorderPanelAfterCollapse() {
        pendingHideTask?.cancel()
        let delay = collapseDuration
        pendingHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, !self.isRecorderPanelVisible else { return }
            self.pendingHideTask = nil
            self.hideRecorderPanel()
        }
    }

    // MARK: - Panel Invalidation

    /// Recorder panels must not outlive a sleep/wake cycle or a display reconfiguration.
    ///
    /// `NotchWindowManager.show()` already rebuilds a panel that is not on screen, so the work
    /// here is only about the panel that is currently *hidden but retained*: dropping it frees
    /// the window early and keeps `destroyWindow()` on a path that actually runs. When a
    /// dictation is in progress the panel stays put and is only repositioned, so an active
    /// session never loses its UI.
    ///
    /// `didChangeScreenParameters` fires several times per reconfiguration and displays need a
    /// moment to settle afterwards, so the work is debounced and re-armed on every event
    /// instead of guessing a single settle delay.
    private func invalidatePanels(reason: String) {
        panelInvalidationTask?.cancel()
        panelInvalidationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            self.applyPanelInvalidation(reason: reason)
        }
    }

    private func applyPanelInvalidation(reason: String) {
        guard isRecorderPanelVisible else {
            logger.notice("Discarding idle recorder panels (\(reason, privacy: .public))")
            notchWindowManager?.destroyWindow()
            notchWindowManager = nil
            miniWindowManager?.destroyWindow()
            miniWindowManager = nil
            return
        }

        logger.notice("Repositioning visible recorder panel (\(reason, privacy: .public))")
        showRecorderPanel()
    }

    private func rebuildVisiblePanel(previousStyle: RecorderPanelStyle) {
        guard isRecorderPanelVisible else { return }

        switch previousStyle {
        case .notch:
            notchWindowManager?.destroyWindow()
            notchWindowManager = nil
        case .mini:
            miniWindowManager?.destroyWindow()
            miniWindowManager = nil
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard self.isRecorderPanelVisible else { return }
            self.showRecorderPanel()
        }
    }

    // MARK: - Recorder Panel Management

    /// `screen` is where the panel should appear if this call opens it; nil uses the usual screen.
    func toggleRecorderPanel(modeId: UUID? = nil, on screen: NSScreen? = nil) async {
        guard let engine = engine else { return }

        if isRecorderPanelVisible {
            switch engine.recordingState {
            case .recording:
                await engine.toggleRecord(modeId: modeId)
            case .starting:
                // A push-to-talk release (or a second toggle press) that lands while the mic is
                // still opening is the user finishing, not cancelling, and cancelling here threw
                // the utterance away. The engine cannot stop a unit that has not started, so
                // wait for the start to land — bounded, so a start that never completes can
                // still be cancelled the old way.
                guard !isWaitingForRecordingStart else { return }
                isWaitingForRecordingStart = true
                let started = await waitForRecordingToStart(engine)
                isWaitingForRecordingStart = false
                if started {
                    await engine.toggleRecord(modeId: modeId)
                } else if engine.recordingState == .starting {
                    await cancelRecording()
                }
            case .transcribing, .enhancing:
                await cancelRecording()
            case .idle:
                if engine.assistantSession.canSendFollowUp {
                    SoundManager.shared.playStartSound()
                    await engine.toggleRecord(
                        modeId: modeId,
                        isAssistantFollowUp: true
                    )
                } else {
                    await dismissRecorderPanel()
                }
            case .busy:
                await dismissRecorderPanel()
            }
        } else {
            SoundManager.shared.playStartSound()
            requestedScreen = screen
            isRecorderPanelVisible = true
            await engine.toggleRecord(modeId: modeId)
        }
    }

    private var isWaitingForRecordingStart = false
    static let recordingStartWaitTimeout: TimeInterval = 2

    /// True once the engine reports `.recording`; false when the start was abandoned (the state
    /// left `.starting` for anything else) or the timeout passed while it was still starting.
    private func waitForRecordingToStart(_ engine: VoxOSEngine) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(Self.recordingStartWaitTimeout)
        while engine.recordingState == .starting, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        return engine.recordingState == .recording
    }

    func dismissRecorderPanel() async {
        guard let engine = engine else { return }

        // Reset first so the band collapses while its window is still on screen, then let the
        // close animation play before the window goes. Clearing the flag schedules that hide
        // (see isRecorderPanelVisible and hideRecorderPanelAfterCollapse), so it is not repeated here.
        engine.assistantSession.reset()
        isRecorderPanelVisible = false
    }

    func resetOnLaunch() async {
        guard let engine = engine else { return }
        logger.notice("Resetting recording state on launch")
        await engine.resetRecordingSession()
        hideRecorderPanel()
        isRecorderPanelVisible = false
        engine.assistantSession.reset()
    }

    func cancelRecording() async {
        DictationSend.clearOnce()
        guard let engine = engine else { return }
        await engine.cancelRecording()
        await dismissRecorderPanel()
    }

    // MARK: - Notification Handling

    private func setupNotifications() {
        guard !didSetupNotifications else { return }
        didSetupNotifications = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleToggleRecorderPanelNotification),
            name: .toggleRecorderPanel,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDismissRecorderPanelNotification),
            name: .dismissRecorderPanel,
            object: nil
        )
        lifecycleCancellable = LifecycleObserver.shared.publisher(
            for: [.systemDidWake, .displaysDidWake, .screenConfigurationChanged]
        ).sink { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .systemDidWake:
                    self.invalidatePanels(reason: "system wake")
                case .displaysDidWake:
                    self.invalidatePanels(reason: "displays wake")
                case .screenConfigurationChanged:
                    self.invalidatePanels(reason: "screen parameters changed")
                default:
                    break
                }
            }
        }
    }

    @objc public func handleToggleRecorderPanelNotification() {
        Task {
            await toggleRecorderPanel()
        }
    }

    @objc public func handleDismissRecorderPanelNotification() {
        Task {
            switch engine?.recordingState {
            case .starting, .recording, .transcribing, .enhancing:
                await cancelRecording()
            case .idle, .busy, nil:
                await dismissRecorderPanel()
            }
        }
    }
}
