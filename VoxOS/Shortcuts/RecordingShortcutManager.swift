import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
class RecordingShortcutManager: ObservableObject {
    @Published var primaryRecordingShortcut: ShortcutSelection {
        didSet {
            UserDefaults.standard.set(primaryRecordingShortcut.rawValue, forKey: "primaryRecordingShortcut")
            refreshShortcutMonitoring()
        }
    }
    @Published var secondaryRecordingShortcut: ShortcutSelection {
        didSet {
            if secondaryRecordingShortcut == .none {
                ShortcutStore.setShortcut(nil, for: .secondaryRecording)
            }
            UserDefaults.standard.set(secondaryRecordingShortcut.rawValue, forKey: "secondaryRecordingShortcut")
            refreshShortcutMonitoring()
        }
    }
    @Published var primaryRecordingShortcutMode: Mode {
        didSet {
            UserDefaults.standard.set(primaryRecordingShortcutMode.rawValue, forKey: "primaryRecordingShortcutMode")
            primaryRecordingShortcutModeSource.primaryMode = primaryRecordingShortcutMode
        }
    }
    @Published var secondaryRecordingShortcutMode: Mode {
        didSet {
            UserDefaults.standard.set(secondaryRecordingShortcutMode.rawValue, forKey: "secondaryRecordingShortcutMode")
        }
    }
    @Published var isMiddleClickToggleEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isMiddleClickToggleEnabled, forKey: "isMiddleClickToggleEnabled")
            refreshShortcutMonitoring()
        }
    }
    @Published var middleClickActivationDelay: Int {
        didSet {
            UserDefaults.standard.set(middleClickActivationDelay, forKey: "middleClickActivationDelay")
        }
    }

    private var engine: VoxOSEngine
    private var recorderUIManager: RecorderUIManager
    private var recorderPanelShortcutManager: RecorderPanelShortcutManager
    private let modeShortcutManager: ModeShortcutManager
    private let shortcutMonitor = ShortcutMonitor()
    private var shortcutChangeObserver: NSObjectProtocol?
    private let shortcutModeHandler: RecordingShortcutModeHandler
    private let primaryRecordingShortcutModeSource: RecordingShortcutModeSource
    private let autoSend: AgentAutoSend

    // MARK: - Helper Properties
    private var canHandleShortcutAction: Bool {
        Self.canHandleShortcutAction(for: engine.recordingState)
    }

    // Middle-click event monitoring
    private var middleClickMonitors: [Any?] = []
    private var middleClickTask: Task<Void, Never>?

    enum Mode: String, CaseIterable {
        case toggle = "toggle"
        case pushToTalk = "pushToTalk"
        case hybrid = "hybrid"

        var displayName: String {
            switch self {
            case .toggle: return String(localized: "Toggle")
            case .pushToTalk: return String(localized: "Push to Talk")
            case .hybrid: return String(localized: "Hybrid")
            }
        }
    }

    enum ShortcutSelection: String, CaseIterable {
        case none = "none"
        case custom = "custom"

        var displayName: String {
            switch self {
            case .none: return String(localized: "None")
            case .custom: return String(localized: "Custom")
            }
        }
    }

    private static func canHandleShortcutAction(for recordingState: RecordingState) -> Bool {
        recordingState != .transcribing && recordingState != .enhancing && recordingState != .busy
    }

    /// VoiceOS-style default: hold fn to talk, tap fn for hands-free, double-tap fn for Agent.
    static let fnShortcut = Shortcut.modifierOnly(keyCode: UInt16(kVK_Function), modifierFlags: [.function])
    /// Double-tapping this modifier (default: either Control key) opens the Agent, or switches a
    /// running recording into Agent mode.
    static let agentTapShortcut = Shortcut.modifierOnly(keyCode: nil, modifierFlags: [.control])
    static let agentDoubleTapWindow: TimeInterval = 0.4
    static let agentTapMaxHold: TimeInterval = 0.35

    private var agentTapDownAt: TimeInterval?
    private var agentLastTapUpAt: TimeInterval?

    init(engine: VoxOSEngine, recorderUIManager: RecorderUIManager) {
        ShortcutMigration.migrateLegacyShortcutsIfNeeded()
        ShortcutStore.seedShortcut(Self.fnShortcut, for: .primaryRecording)
        ShortcutStore.seedShortcut(Self.agentTapShortcut, for: .agentDoubleTap)

        self.primaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(
            action: .primaryRecording,
            allowsNone: false
        )
        self.secondaryRecordingShortcut = ShortcutMigration.migrateShortcutSelection(
            action: .secondaryRecording,
            allowsNone: true
        )

        let primaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(
            for: .primaryRecording
        )
        self.primaryRecordingShortcutMode = primaryRecordingShortcutMode
        self.secondaryRecordingShortcutMode = ShortcutMigration.migrateShortcutMode(
            for: .secondaryRecording
        )

        self.isMiddleClickToggleEnabled = UserDefaults.standard.bool(forKey: "isMiddleClickToggleEnabled")
        self.middleClickActivationDelay = UserDefaults.standard.integer(forKey: "middleClickActivationDelay")

        let autoSend = AgentAutoSend(engine: engine, recorderUIManager: recorderUIManager)
        self.autoSend = autoSend

        let shortcutModeHandler = RecordingShortcutModeHandler(
            canHandleShortcutAction: {
                Self.canHandleShortcutAction(for: engine.recordingState)
            },
            isRecorderVisible: {
                recorderUIManager.isRecorderPanelVisible
            },
            recordingState: {
                engine.recordingState
            },
            toggleRecorderPanel: { modeId in
                await recorderUIManager.toggleRecorderPanel(modeId: modeId)
            },
            cancelRecording: {
                await recorderUIManager.cancelRecording()
            },
            toggleAgentMode: { [weak autoSend] in
                let switched = Self.toggleAgentMode()
                if switched { autoSend?.startIfAgentMode() }
                return switched
            },
            onHandsFreeRecordingStarted: { [weak autoSend] in
                autoSend?.startIfAgentMode()
            }
        )

        let primaryRecordingShortcutModeSource = RecordingShortcutModeSource(
            primaryMode: primaryRecordingShortcutMode
        )

        self.engine = engine
        self.recorderUIManager = recorderUIManager
        self.recorderPanelShortcutManager = RecorderPanelShortcutManager(recorderUIManager: recorderUIManager)
        self.shortcutModeHandler = shortcutModeHandler
        self.primaryRecordingShortcutModeSource = primaryRecordingShortcutModeSource
        self.modeShortcutManager = ModeShortcutManager(
            modeProvider: {
                primaryRecordingShortcutModeSource.primaryMode
            },
            shortcutModeHandler: shortcutModeHandler
        )

        shortcutChangeObserver = NotificationCenter.default.addObserver(
            forName: ShortcutStore.shortcutDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshShortcutMonitoring()
            }
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            self.refreshShortcutMonitoring()
        }
    }

    private func refreshShortcutMonitoring() {
        removeAllMonitoring()

        refreshShortcutMonitor()
        setupMiddleClickMonitoring()
    }

    private func setupMiddleClickMonitoring() {
        guard isMiddleClickToggleEnabled else { return }

        // Mouse Down
        let downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
            guard let self = self, event.buttonNumber == 2 else { return }

            self.middleClickTask?.cancel()
            self.middleClickTask = Task {
                do {
                    let delay = UInt64(self.middleClickActivationDelay) * 1_000_000  // ms to ns
                    try await Task.sleep(nanoseconds: delay)

                    guard self.isMiddleClickToggleEnabled, !Task.isCancelled else { return }

                    Task { @MainActor in
                        guard self.canHandleShortcutAction else { return }
                        await self.recorderUIManager.toggleRecorderPanel()
                    }
                } catch {
                    // Cancelled
                }
            }
        }

        // Mouse Up
        let upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
            guard let self = self, event.buttonNumber == 2 else { return }
            self.middleClickTask?.cancel()
        }

        middleClickMonitors = [downMonitor, upMonitor]
    }

    private func refreshShortcutMonitor() {
        let primaryShortcut = primaryRecordingShortcut == .custom ? ShortcutStore.shortcut(for: .primaryRecording) : nil
        let secondaryShortcut =
            secondaryRecordingShortcut == .custom ? ShortcutStore.shortcut(for: .secondaryRecording) : nil
        var shortcuts = ShortcutStore.shortcuts(for: ShortcutAction.globalUtilityActions)
        var interruptibleRecordingActions = Set<ShortcutAction>()

        if let agentTap = ShortcutStore.shortcut(for: .agentDoubleTap) {
            shortcuts[.agentDoubleTap] = agentTap
            interruptibleRecordingActions.insert(.agentDoubleTap)
        }

        if let primaryShortcut {
            shortcuts[.primaryRecording] = primaryShortcut
            interruptibleRecordingActions.insert(.primaryRecording)
        }

        if let secondaryShortcut {
            shortcuts[.secondaryRecording] = secondaryShortcut
            interruptibleRecordingActions.insert(.secondaryRecording)
        }

        shortcutMonitor.start(
            shortcuts: shortcuts,
            interruptibleActions: interruptibleRecordingActions,
            onKeyDown: { [weak self] action, eventTime in
                Task { @MainActor in
                    guard let self else { return }
                    if action == .agentDoubleTap {
                        self.agentTapDownAt = eventTime
                        return
                    }
                    guard let mode = self.recordingMode(for: action) else { return }
                    await self.shortcutModeHandler.handleKeyDown(
                        action: action,
                        eventTime: eventTime,
                        mode: mode
                    )
                }
            },
            onKeyUp: { [weak self] action, eventTime in
                Task { @MainActor in
                    guard let self else { return }
                    if action == .agentDoubleTap {
                        await self.handleAgentTapUp(eventTime: eventTime)
                        return
                    }
                    if let mode = self.recordingMode(for: action) {
                        await self.shortcutModeHandler.handleKeyUp(
                            action: action,
                            eventTime: eventTime,
                            mode: mode
                        )
                    } else {
                        await self.handleGlobalShortcut(action)
                    }
                }
            },
            onShortcutInterrupted: { [weak self] action, _ in
                Task { @MainActor in
                    guard let self else { return }
                    if action == .agentDoubleTap {
                        // Control was part of a real key combo, not a tap.
                        self.agentTapDownAt = nil
                        self.agentLastTapUpAt = nil
                        return
                    }
                    guard self.recordingMode(for: action) != nil else { return }
                    await self.shortcutModeHandler.handleInterruption(action: action)
                }
            }
        )
    }

    private func handleAgentTapUp(eventTime: TimeInterval) async {
        guard let downAt = agentTapDownAt else { return }
        agentTapDownAt = nil
        guard eventTime - downAt <= Self.agentTapMaxHold else {
            agentLastTapUpAt = nil
            return
        }
        if let last = agentLastTapUpAt, eventTime - last <= Self.agentDoubleTapWindow {
            agentLastTapUpAt = nil
            await triggerAgent()
        } else {
            agentLastTapUpAt = eventTime
        }
    }

    /// Control double-tap: switch a live recording into Agent mode, or start an Agent
    /// recording from idle. Either way the request auto-sends after the user stops talking.
    func triggerAgent() async {
        let manager = ModeManager.shared
        guard let agent = manager.getConfiguration(with: StarterModeCatalog.agentId), agent.isEnabled else { return }

        if recorderUIManager.isRecorderPanelVisible, engine.recordingState == .recording {
            if manager.currentEffectiveConfiguration?.id != agent.id {
                Self.toggleAgentMode()
            }
            autoSend.startIfAgentMode()
            return
        }

        guard canHandleShortcutAction else { return }
        Self.previousModeBeforeAgent = manager.currentEffectiveConfiguration?.id
        manager.setActiveConfiguration(agent)
        await recorderUIManager.toggleRecorderPanel(modeId: agent.id)
        autoSend.startWhenRecording()
    }

    private func recordingMode(for action: ShortcutAction) -> Mode? {
        switch action {
        case .primaryRecording:
            return primaryRecordingShortcutMode
        case .secondaryRecording:
            return secondaryRecordingShortcutMode
        default:
            return nil
        }
    }

    private func handleGlobalShortcut(_ action: ShortcutAction) async {
        switch action {
        case .pasteLastTranscription:
            LastTranscriptionService.pasteLastTranscription(from: engine.modelContext)
        case .pasteLastEnhancement:
            LastTranscriptionService.pasteLastEnhancement(from: engine.modelContext)
        case .retryLastTranscription:
            LastTranscriptionService.retryLastTranscription(
                from: engine.modelContext,
                transcriptionModelManager: engine.transcriptionModelManager,
                serviceRegistry: engine.serviceRegistry,
                enhancementService: engine.enhancementService
            )
        case .openHistoryWindow:
            HistoryWindowController.shared.showHistoryWindow(
                modelContainer: engine.modelContext.container,
                engine: engine
            )
        case .quickAddToDictionary:
            DictionaryQuickAddManager.shared.toggle(modelContainer: engine.modelContext.container)
        case .captureSystemAudio:
            await SystemAudioCaptureController.shared.toggleCapture()
        case .recallSystemAudio:
            await SystemAudioCaptureController.shared.transcribeRecentAudio()
        default:
            break
        }
    }

    private func removeAllMonitoring() {
        shortcutMonitor.stop()

        for monitor in middleClickMonitors {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        middleClickMonitors = []
        middleClickTask?.cancel()

        shortcutModeHandler.reset()
    }

    /// Switches the live recording between the Agent starter mode and the mode that was
    /// active before it. Returns false when there is no enabled Agent mode to switch to.
    @discardableResult
    static func toggleAgentMode() -> Bool {
        let manager = ModeManager.shared
        guard let agent = manager.getConfiguration(with: StarterModeCatalog.agentId), agent.isEnabled else {
            return false
        }

        if manager.currentEffectiveConfiguration?.id == agent.id {
            let previous = previousModeBeforeAgent.flatMap { manager.getConfiguration(with: $0) }
            let target = (previous?.isEnabled == true ? previous : nil) ?? manager.getDefaultConfiguration()
            previousModeBeforeAgent = nil
            manager.setActiveConfiguration(target)
            NotificationManager.shared.showNotification(
                title: target.map { String(format: String(localized: "%@ mode"), $0.name) }
                    ?? String(localized: "Dictation mode"),
                type: .info,
                duration: 1.2
            )
        } else {
            previousModeBeforeAgent = manager.currentEffectiveConfiguration?.id
            manager.setActiveConfiguration(agent)
            NotificationManager.shared.showNotification(
                title: String(localized: "Agent mode — say what to do"),
                type: .info,
                duration: 1.5
            )
        }
        return true
    }

    private static var previousModeBeforeAgent: UUID?

    /// Sets the primary shortcut to the fn key in hybrid mode (hold = push-to-talk, tap = hands-free).
    func useFnKeyPreset() {
        ShortcutStore.setShortcut(Self.fnShortcut, for: .primaryRecording)
        primaryRecordingShortcut = .custom
        primaryRecordingShortcutMode = .hybrid
        updateShortcutStatus()
    }

    var isPrimaryShortcutFnKey: Bool {
        primaryRecordingShortcut == .custom && ShortcutStore.shortcut(for: .primaryRecording) == Self.fnShortcut
    }

    /// macOS "Press 🌐 key to" setting (com.apple.HIToolbox AppleFnUsageType). 0 = Do Nothing.
    /// Anything else steals a bare fn tap (emoji picker, input source, Apple Dictation).
    static var systemFnKeyActionIsOff: Bool {
        guard let defaults = UserDefaults(suiteName: "com.apple.HIToolbox"),
            defaults.object(forKey: "AppleFnUsageType") != nil
        else {
            return false
        }
        return defaults.integer(forKey: "AppleFnUsageType") == 0
    }

    var isShortcutConfigured: Bool {
        let isPrimaryShortcutConfigured =
            primaryRecordingShortcut != .none && ShortcutStore.shortcut(for: .primaryRecording) != nil
        let isSecondaryShortcutConfigured =
            secondaryRecordingShortcut == .none || ShortcutStore.shortcut(for: .secondaryRecording) != nil
        return isPrimaryShortcutConfigured && isSecondaryShortcutConfigured
    }

    func updateShortcutStatus() {
        // Called when a shortcut changes
        refreshShortcutMonitoring()
    }

    deinit {
        if let shortcutChangeObserver {
            NotificationCenter.default.removeObserver(shortcutChangeObserver)
        }

        MainActor.assumeIsolated {
            removeAllMonitoring()
        }
    }
}

@MainActor
private final class RecordingShortcutModeSource {
    var primaryMode: RecordingShortcutManager.Mode

    init(primaryMode: RecordingShortcutManager.Mode) {
        self.primaryMode = primaryMode
    }
}

@MainActor
final class RecordingShortcutModeHandler {
    private let canHandleShortcutAction: @MainActor () -> Bool
    private let isRecorderVisible: @MainActor () -> Bool
    private let recordingState: @MainActor () -> RecordingState
    private let toggleRecorderPanel: @MainActor (UUID?) async -> Void
    private let cancelRecording: @MainActor () async -> Void
    private let toggleAgentMode: @MainActor () -> Bool
    private let onHandsFreeRecordingStarted: @MainActor () -> Void

    private var shortcutPressStartTime: TimeInterval?
    private var lastKeyUpTime: TimeInterval?
    private var lastKeyUpAction: ShortcutAction?
    private var isHandsFreeRecording = false
    private var isShortcutPressed = false
    private var activeRecordingShortcutAction: ShortcutAction?
    private var interruptedRecordingActions = Set<ShortcutAction>()
    private var activeShortcutCanCancelAccidentalStart = false
    private var lastShortcutPressTime: TimeInterval?

    private let shortcutPressCooldown: TimeInterval = 0.5
    private let hybridPressThreshold: TimeInterval = 0.5
    /// A second press of the same recording shortcut within this window, while a hands-free
    /// recording is running, flips the recording into Agent mode instead of stopping it.
    static let doubleTapWindow: TimeInterval = 0.45
    static let doubleTapDefaultsKey = "recordingShortcutDoubleTapSwitchesToAgent"
    static var recordingShortcutDoubleTapSwitchesToAgent: Bool {
        UserDefaults.standard.object(forKey: doubleTapDefaultsKey) == nil
            ? false : UserDefaults.standard.bool(forKey: doubleTapDefaultsKey)
    }

    init(
        canHandleShortcutAction: @escaping @MainActor () -> Bool,
        isRecorderVisible: @escaping @MainActor () -> Bool,
        recordingState: @escaping @MainActor () -> RecordingState,
        toggleRecorderPanel: @escaping @MainActor (UUID?) async -> Void,
        cancelRecording: @escaping @MainActor () async -> Void,
        toggleAgentMode: @escaping @MainActor () -> Bool = { false },
        onHandsFreeRecordingStarted: @escaping @MainActor () -> Void = {}
    ) {
        self.canHandleShortcutAction = canHandleShortcutAction
        self.isRecorderVisible = isRecorderVisible
        self.recordingState = recordingState
        self.toggleRecorderPanel = toggleRecorderPanel
        self.cancelRecording = cancelRecording
        self.toggleAgentMode = toggleAgentMode
        self.onHandsFreeRecordingStarted = onHandsFreeRecordingStarted
    }

    func reset() {
        isShortcutPressed = false
        shortcutPressStartTime = nil
        isHandsFreeRecording = false
        activeRecordingShortcutAction = nil
        interruptedRecordingActions.removeAll()
        activeShortcutCanCancelAccidentalStart = false
        lastKeyUpTime = nil
        lastKeyUpAction = nil
    }

    /// True when this key-down is the second tap of a double-tap on the same recording
    /// shortcut while the first tap's hands-free recording is still running.
    private func isDoubleTap(action: ShortcutAction, eventTime: TimeInterval) -> Bool {
        guard let lastKeyUpTime, lastKeyUpAction == action else { return false }
        return eventTime - lastKeyUpTime <= Self.doubleTapWindow
            && isHandsFreeRecording
            && isRecorderVisible()
            && recordingState() == .recording
    }

    func handleKeyDown(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        modeId: UUID? = nil
    ) async {
        if interruptedRecordingActions.remove(action) != nil {
            return
        }

        // Double-tap (primary/secondary shortcut only): keep recording, switch to Agent mode.
        // Off by default since the Control double-tap took over; kept for users who prefer it.
        if modeId == nil, Self.recordingShortcutDoubleTapSwitchesToAgent,
            isDoubleTap(action: action, eventTime: eventTime)
        {
            lastKeyUpTime = nil
            lastKeyUpAction = nil
            if toggleAgentMode() {
                return
            }
        }

        if let lastTrigger = lastShortcutPressTime,
            eventTime - lastTrigger < shortcutPressCooldown
        {
            return
        }

        guard !isShortcutPressed else {
            return
        }
        isShortcutPressed = true
        activeRecordingShortcutAction = action
        activeShortcutCanCancelAccidentalStart = canCurrentShortcutPressCancelAccidentalStart
        lastShortcutPressTime = eventTime
        shortcutPressStartTime = eventTime

        switch mode {
        case .toggle, .hybrid:
            if isHandsFreeRecording {
                isHandsFreeRecording = false
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
                return
            }

            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }

        case .pushToTalk:
            if !isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }
        }
    }

    func handleKeyUp(
        action: ShortcutAction,
        eventTime: TimeInterval,
        mode: RecordingShortcutManager.Mode,
        modeId: UUID? = nil
    ) async {
        guard isShortcutPressed, activeRecordingShortcutAction == action else { return }
        isShortcutPressed = false
        activeRecordingShortcutAction = nil
        activeShortcutCanCancelAccidentalStart = false
        lastKeyUpTime = eventTime
        lastKeyUpAction = action

        switch mode {
        case .toggle:
            isHandsFreeRecording = true
            onHandsFreeRecordingStarted()

        case .pushToTalk:
            if isRecorderVisible() {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            }

        case .hybrid:
            let pressDuration = shortcutPressStartTime.map { eventTime - $0 } ?? 0
            if pressDuration >= hybridPressThreshold && recordingState() == .recording {
                guard canHandleShortcutAction() else { return }
                await toggleRecorderPanel(modeId)
            } else {
                isHandsFreeRecording = true
                onHandsFreeRecordingStarted()
            }
        }

        shortcutPressStartTime = nil
    }

    func handleInterruption(action: ShortcutAction) async {
        guard isShortcutPressed, activeRecordingShortcutAction == action else {
            if canCurrentShortcutPressCancelAccidentalStart {
                interruptedRecordingActions.insert(action)
            }
            return
        }

        guard activeShortcutCanCancelAccidentalStart else { return }

        reset()
        await cancelRecording()
    }

    private var canCurrentShortcutPressCancelAccidentalStart: Bool {
        !isRecorderVisible() && recordingState() == .idle
    }
}
