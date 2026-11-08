import AppKit
import Combine
import SwiftUI
import os

final class ClaudeCodeNotchPanel: NSPanel {
    /// Only while an "Other…" answer is being typed: otherwise answering a request must not take
    /// focus from the app the user is typing into.
    var acceptsKeyboard = false
    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect, styleMask: [.nonactivatingPanel, .fullSizeContentView, .hudWindow],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        canHide = false
        // Above the idle tab, below the recorder.
        level = .statusBar + 2
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        styleMask.remove(.titled)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovable = false
    }
}

// MARK: - Manager

/// Owns the panel and decides what it shows.
@MainActor
final class ClaudeCodeNotchManager {
    private weak var uiManager: RecorderUIManager?
    private let activity: ClaudeCodeActivity
    private var panel: ClaudeCodeNotchPanel?
    private var model: ClaudeCodeNotchModel?
    private var screen: NSScreen?
    private var cancellables: Set<AnyCancellable> = []
    private var resizeTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    /// The request the user clicked the waiting band for: it shows as a card from then on.
    private var revealed: UUID?
    /// The reply already read aloud, so a refresh never reads it twice.
    private var spokenReply: UUID?
    /// Each CLI's terminal app, found once per CLI process.
    private var terminals: [Int32: pid_t?] = [:]
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "ClaudeCodeNotch")

    init(uiManager: RecorderUIManager, activity: ClaudeCodeActivity = .shared) {
        self.uiManager = uiManager
        self.activity = activity

        // @Published sends before the value is stored; hopping to the next run loop pass reads
        // the new value.
        activity.$prompts.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        activity.$sessions.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        activity.$reply.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        ClaudeCodeIntegration.shared.$isOffering.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        uiManager.$isRecorderPanelVisible.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        uiManager.$isNotchHomeVisible.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        // A request waiting quietly becomes a card once its terminal is no longer in front.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        LifecycleObserver.shared.publisher(for: [.screenConfigurationChanged, .systemDidWake])
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.destroyPanel()
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    private func refresh() {
        guard let uiManager else { return }
        // On another display now: built again there, unless a card is up mid-answer.
        if let screen, let target = NotchScreens.target(), !NotchScreens.same(screen, target),
            model?.content.isCard != true
        {
            destroyPanel()
        }
        let now = Date()
        if let revealed, !activity.prompts.contains(where: { $0.id == revealed }) { self.revealed = nil }
        let first = activity.prompts.first
        // Not while that session's terminal is in front: the reply is right there.
        let shownReply = activity.reply.flatMap { reply in
            terminalIsInFront(sessionID: reply.sessionID) ? nil : reply
        }
        if let shownReply, shownReply.id != spokenReply, ClaudeCodeIntegration.speaksReplies {
            spokenReply = shownReply.id
            ClaudeCodeSpeech.speak(shownReply.text)
        }
        let quiet =
            ClaudeCodeIntegration.quietInTerminal
            && first.map { $0.id != revealed && terminalIsInFront(for: $0) } == true
        let content = ClaudeCodeNotch.content(
            prompts: activity.prompts, status: activity.status(now: now),
            enabled: ClaudeCodeIntegration.isEnabled && MasterSwitches.notchEnabled,
            approvalsEnabled: ClaudeCodeIntegration.approvalsEnabled,
            statusEnabled: ClaudeCodeIntegration.statusEnabled,
            recorderVisible: uiManager.isRecorderPanelVisible,
            offering: ClaudeCodeIntegration.shared.isOffering && MasterSwitches.notchEnabled,
            homeVisible: uiManager.isNotchHomeVisible, quiet: quiet, reply: shownReply)
        scheduleTick(after: now)
        let sharing: NSWindow.SharingType = NotchHome.hiddenFromCapture ? .none : .readOnly
        if let panel, panel.sharingType != sharing { panel.sharingType = sharing }
        apply(content)
        let terminal = first.flatMap(terminal(for:))
        if model?.terminal != terminal { model?.terminal = terminal }
        if uiManager.isClaudeCodeSurfaceVisible != (content != .hidden) {
            uiManager.isClaudeCodeSurfaceVisible = content != .hidden
        }
        if uiManager.isClaudeCodeCardVisible != content.hidesHome {
            uiManager.isClaudeCodeCardVisible = content.hidesHome
        }
    }

    /// The app running the request's session is the one in front.
    private func terminalIsInFront(for prompt: ClaudeCodeActivity.PermissionPrompt) -> Bool {
        terminalIsInFront(sessionID: prompt.sessionID)
    }

    private func terminalIsInFront(sessionID: String) -> Bool {
        guard let terminal = terminal(sessionID: sessionID) else { return false }
        return terminal == NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    private func terminal(for prompt: ClaudeCodeActivity.PermissionPrompt) -> pid_t? {
        terminal(sessionID: prompt.sessionID)
    }

    private func terminal(sessionID: String) -> pid_t? {
        guard let cli = activity.sessions[sessionID]?.cliPID else { return nil }
        if terminals.count > 64 { terminals = [:] }
        let terminal = terminals[cli] ?? ClaudeCodeTerminal.app(hosting: cli)
        terminals[cli] = terminal
        return terminal
    }

    /// Activation through Launch Services, which brings an app forward from a background app
    /// such as VoxOS; asking the app to activate itself is refused there.
    private func openTerminal(_ pid: pid_t) {
        guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return }
        ActivityTrail.mark("claude terminal opened from the notch")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    private func reveal() {
        guard let first = activity.prompts.first else { return }
        ActivityTrail.mark("claude waiting band clicked")
        revealed = first.id
        refresh()
    }

    /// "Done" fades by itself; nothing else happens then, so wake up for it.
    private func scheduleTick(after now: Date) {
        tickTask?.cancel()
        guard let next = activity.nextStatusChange(after: now) else { return }
        tickTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, next.timeIntervalSince(now) + 0.05)))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func apply(_ content: ClaudeCodeNotch.Content) {
        if content == .hidden {
            guard let panel, let model, model.content != .hidden else { return }
            resizeTask?.cancel()
            model.content = .hidden
            resizeTask = Task { @MainActor [weak panel] in
                try? await Task.sleep(for: .seconds(NotchDesign.closeDuration))
                guard !Task.isCancelled else { return }
                panel?.orderOut(nil)
            }
            return
        }

        // Every tool call refreshes; most of them change nothing on screen.
        if let panel, let model, panel.isVisible, model.content == content { return }
        if panel == nil { buildPanel() }
        guard let panel, let model, let screen else { return }
        resizeTask?.cancel()

        let target = ClaudeCodeNotch.size(for: content, notchWidth: model.notchWidth, notchHeight: model.notchHeight)
        let wasVisible = panel.isVisible && model.content != .hidden
        let current = panel.frame.size
        let grows = !wasVisible || (target.width >= current.width && target.height >= current.height)
        panel.hasShadow = content.isCard

        if grows {
            // The window grows first so the shape has room to animate into.
            panel.setFrame(ClaudeCodeNotch.frame(for: target, screenFrame: screen.frame), display: true)
            panel.orderFrontRegardless()
            if wasVisible {
                model.content = content
            } else {
                model.content = .hidden
                DispatchQueue.main.async { [weak model] in model?.content = content }
            }
        } else {
            // The shape shrinks first; the window follows once it has.
            model.content = content
            panel.orderFrontRegardless()
            resizeTask = Task { @MainActor [weak panel, weak self] in
                try? await Task.sleep(for: .seconds(NotchDesign.closeDuration))
                guard !Task.isCancelled, let panel, let screen = self?.screen else { return }
                panel.setFrame(ClaudeCodeNotch.frame(for: target, screenFrame: screen.frame), display: true)
            }
        }
    }

    /// The notched display when there is one, as for the idle tab; otherwise the usual screen,
    /// where the band hangs from the menu bar.
    /// Notch Home's display (NotchScreens): the notched one, or the menu bar's, or the one in use.
    private func buildPanel() {
        guard let screen = NotchScreens.target() ?? RecorderScreenResolver.resolve(),
            let metrics = NotchRecorderPanel.calculateWindowMetrics(on: screen)
        else {
            logger.error("Claude Code notch not built: no screen")
            return
        }
        self.screen = screen
        let model = ClaudeCodeNotchModel(notchWidth: metrics.notchWidth, notchHeight: metrics.notchHeight)
        let size = ClaudeCodeNotch.size(for: .hidden, notchWidth: metrics.notchWidth, notchHeight: metrics.notchHeight)
        let panel = ClaudeCodeNotchPanel(contentRect: ClaudeCodeNotch.frame(for: size, screenFrame: screen.frame))
        let view = ClaudeCodeNotchView(
            model: model,
            onDecision: { [weak activity] id, decision in activity?.decide(id, decision) },
            onOffer: { turnOn in ClaudeCodeIntegration.shared.answerOffer(turnOn: turnOn) },
            onKeyboard: { [weak panel] wanted in
                guard let panel else { return }
                panel.acceptsKeyboard = wanted
                if wanted { panel.makeKey() } else { panel.resignKey() }
            },
            onReveal: { [weak self] in self?.reveal() },
            onSpeak: { ClaudeCodeSpeech.speak($0) },
            onDismissReply: { [weak activity] in
                ClaudeCodeSpeech.stop()
                activity?.dismissReply()
            },
            onOpenTerminal: { [weak self] pid in self?.openTerminal(pid) })
        panel.contentView = NotchRecorderHostingController(rootView: view).view
        panel.sharingType = NotchHome.hiddenFromCapture ? .none : .readOnly
        self.model = model
        self.panel = panel
        logger.notice(
            "Claude Code notch built notch=\(metrics.notchWidth, privacy: .public)x\(metrics.notchHeight, privacy: .public)"
        )
    }

    private func destroyPanel() {
        resizeTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
        model = nil
        screen = nil
    }
}
