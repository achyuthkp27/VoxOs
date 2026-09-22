import AppKit
import CoreGraphics
import Foundation
import os

final class ShortcutMonitor {
    enum EventKind {
        case keyDown
        case keyUp
        case flagsChanged
    }

    private struct ShortcutState {
        var shortcut: Shortcut
        var isDown = false
        var pressedAt: TimeInterval?
        var isInterrupted = false
    }

    /// Who registered a shortcut. Each subsystem owns a disjoint slice of `ShortcutAction`, so
    /// one tap can serve all of them and an action always maps back to exactly one owner.
    enum Owner: String, CaseIterable {
        case recording
        case mode
        case recorderPanel
        case testing
    }

    private struct Registration {
        var interruptibleActions: Set<ShortcutAction>
        var onKeyDown: (ShortcutAction, TimeInterval) -> Void
        var onKeyUp: (ShortcutAction, TimeInterval) -> Void
        var onShortcutInterrupted: ((ShortcutAction, TimeInterval) -> Void)?
    }

    private var shortcuts: [ShortcutAction: ShortcutState] = [:]
    private var interruptibleActions: Set<ShortcutAction> = []
    private var registrations: [Owner: Registration] = [:]
    private var ownerByAction: [ShortcutAction: Owner] = [:]
    private var eventTap: CFMachPort?
    private var eventTapRunLoopSource: CFRunLoopSource?
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "ShortcutMonitor")

    /// The tap runs here rather than on the main run loop.
    ///
    /// This is an active, head-inserted session tap on every keyDown, keyUp and flagsChanged, so
    /// the whole system's keyboard input passes through this callback before reaching any app.
    /// On the main run loop that made keyboard delivery depend on VoxOS's main thread being free:
    /// any hitch — SwiftUI layout, a SwiftData fetch, loading a model — stalled typing everywhere
    /// until it cleared, while the trackpad carried on because pointer events are not in the
    /// mask. A dedicated thread keeps keystrokes flowing no matter what the UI is doing.
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?
    /// Bumped on every install and every stop, so a tap thread that wakes up late can tell it
    /// belongs to a generation that has already been torn down.
    private var tapGeneration: UInt64 = 0

    /// Guards the state below, which the tap thread now touches alongside start/stop callers.
    private let stateLock = NSLock()

    /// A failed `tapCreate` used to be permanent for the life of the process. At launch the tap
    /// is built before Accessibility is trusted, so it fails, and macOS never calls back when the
    /// grant arrives. `RecordingShortcutManager` hid that by rebuilding its monitor on any
    /// shortcut or setting change, but `ModeShortcutManager` only rebuilds when a mode shortcut
    /// itself changes — so a launch-time failure left every mode shortcut dead for the whole
    /// session. Re-attempt on a backoff instead, and only while shortcuts are registered and no
    /// tap exists, so a healthy monitor schedules nothing.
    private var tapRetryGeneration: UInt64 = 0
    private var tapRetryDelay: TimeInterval = ShortcutMonitor.initialTapRetryDelay

    /// Test seams. `tapCreate` only succeeds for a process macOS trusts for Accessibility, and a
    /// test host cannot be granted that from code, so the failure path this retry exists for is
    /// otherwise unreachable from a unit test.
    var simulatesEventTapInstallFailure = false
    /// Fires whenever the tap is actually torn down, so a test can prove that re-registering an
    /// owner leaves a live tap alone instead of rebuilding it.
    var onEventTapTeardown: (() -> Void)?
    var retryScheduler: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private var tapReenableCount = 0
    private var tapReenableWindowStart: TimeInterval = 0

    private static let shortcutInterruptionWindow: TimeInterval = 1.0
    private static let initialTapRetryDelay: TimeInterval = 1.0
    private static let maxTapRetryDelay: TimeInterval = 30.0
    private static let tapReenableWindow: TimeInterval = 10.0
    private static let tapStartVerificationDelay: TimeInterval = 1.0
    private static let maxTapReenablesPerWindow = 3

    /// The tap callback cannot hold a strong reference to the monitor (that would keep it alive
    /// forever) and must not hold an unretained one (the monitor can be freed while a callback is
    /// mid-flight, on another thread, which is a use-after-free). It gets this box instead, which
    /// the tap retains and whose weak pointer simply reads nil once the monitor is gone.
    private final class TapContext {
        weak var monitor: ShortcutMonitor?

        init(monitor: ShortcutMonitor) {
            self.monitor = monitor
        }
    }

    /// The one event tap for the whole process.
    ///
    /// Recording, mode and recorder-panel shortcuts used to own a `ShortcutMonitor` each, so the
    /// app installed three active head-inserted session taps and hit every tap-lifecycle hazard
    /// three times. Worse, the recorder panel called start/stop on each show and hide, and
    /// `start()` began by tearing the tap down — so every dictation destroyed and rebuilt a tap
    /// that the entire system's keyboard was routed through. Registering into one shared tap
    /// turns all of that into a dictionary update behind a lock.
    static let shared = ShortcutMonitor()

    deinit {
        teardownTap()
    }

    /// Replaces `owner`'s shortcuts. The tap is created on the first registration and survives
    /// every later one, so re-registering never interrupts keyboard delivery.
    func register(
        owner: Owner,
        shortcuts: [ShortcutAction: Shortcut],
        interruptibleActions: Set<ShortcutAction> = [],
        onKeyDown: @escaping (ShortcutAction, TimeInterval) -> Void,
        onKeyUp: @escaping (ShortcutAction, TimeInterval) -> Void,
        onShortcutInterrupted: ((ShortcutAction, TimeInterval) -> Void)? = nil
    ) {
        stateLock.withLock {
            removeRegistrationLocked(owner: owner)

            for (action, shortcut) in shortcuts {
                self.shortcuts[action] = ShortcutState(shortcut: shortcut)
                ownerByAction[action] = owner
            }

            registrations[owner] = Registration(
                interruptibleActions: interruptibleActions,
                onKeyDown: onKeyDown,
                onKeyUp: onKeyUp,
                onShortcutInterrupted: onShortcutInterrupted
            )

            self.interruptibleActions.formUnion(interruptibleActions)
        }

        syncTapWithRegistrations()
    }

    func unregister(owner: Owner) {
        stateLock.withLock { removeRegistrationLocked(owner: owner) }
        syncTapWithRegistrations()
    }

    /// Caller must hold `stateLock`.
    private func removeRegistrationLocked(owner: Owner) {
        guard registrations.removeValue(forKey: owner) != nil else { return }

        for (action, actionOwner) in ownerByAction where actionOwner == owner {
            ownerByAction.removeValue(forKey: action)
            shortcuts.removeValue(forKey: action)
        }

        interruptibleActions = registrations.values.reduce(into: Set<ShortcutAction>()) {
            $0.formUnion($1.interruptibleActions)
        }
    }

    /// Installs the tap when something is registered and tears it down when nothing is, and does
    /// neither when the tap is already in the right state — which is what keeps a re-registration
    /// from disturbing a live tap.
    private func syncTapWithRegistrations() {
        let (hasShortcuts, hasTap) = stateLock.withLock {
            (!shortcuts.isEmpty, eventTap != nil)
        }

        switch (hasShortcuts, hasTap) {
        case (true, false):
            installEventTapOrScheduleRetry()
        case (false, true):
            teardownTap()
            stateLock.withLock {
                tapRetryGeneration &+= 1
                tapRetryDelay = Self.initialTapRetryDelay
            }
        case (false, false):
            stateLock.withLock {
                tapRetryGeneration &+= 1
                tapRetryDelay = Self.initialTapRetryDelay
            }
        case (true, true):
            break
        }
    }

    @discardableResult
    private func installEventTapOrScheduleRetry() -> Bool {
        if installEventTap() {
            stateLock.withLock { tapRetryDelay = Self.initialTapRetryDelay }
            return true
        }

        scheduleTapInstallRetry()
        return false
    }

    private func scheduleTapInstallRetry() {
        let (generation, delay) = stateLock.withLock { () -> (UInt64, TimeInterval) in
            tapRetryGeneration &+= 1
            let delay = tapRetryDelay
            tapRetryDelay = min(tapRetryDelay * 2, Self.maxTapRetryDelay)
            return (tapRetryGeneration, delay)
        }

        logger.notice(
            "Retrying global shortcut event tap in \(delay, privacy: .public)s (accessibility trusted: \(AXIsProcessTrusted(), privacy: .public))"
        )

        retryScheduler(delay) { [weak self] in
            guard let self else { return }

            // A later start()/stop() bumps the generation, so a stale retry does nothing.
            let isRetryCurrent = self.stateLock.withLock {
                self.tapRetryGeneration == generation && !self.shortcuts.isEmpty && self.eventTap == nil
            }

            guard isRetryCurrent else { return }

            self.installEventTapOrScheduleRetry()
        }
    }

    /// Tears the tap down but keeps the registrations, so a rebuild can follow.
    private func teardownTap() {
        onEventTapTeardown?()

        // Take the whole tap out of the shared state in one locked step, bumping the generation
        // at the same time. The tap thread publishes `tapRunLoop` under this lock after checking
        // the generation, so a thread that has not published yet sees the bump and exits without
        // ever touching a run loop we would no longer know about.
        let (eventTap, source, runLoop, thread) = stateLock.withLock {
            () -> (CFMachPort?, CFRunLoopSource?, CFRunLoop?, Thread?) in
            defer {
                self.eventTap = nil
                self.eventTapRunLoopSource = nil
                self.tapRunLoop = nil
                self.tapThread = nil
                tapGeneration &+= 1
                tapReenableCount = 0
            }
            return (self.eventTap, self.eventTapRunLoopSource, self.tapRunLoop, self.tapThread)
        }

        // Order matters, and getting it wrong freezes the whole machine. While the tap is
        // enabled every keystroke is routed to its port, so it has to be switched off *before*
        // its source leaves the run loop — otherwise there is a window where input is still
        // being handed to a port nobody is draining, and typing stalls everywhere until the
        // invalidate below lands (or the process dies).
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }

        if let source, let runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }

        if let eventTap {
            CFMachPortInvalidate(eventTap)
        }

        thread?.cancel()
        if let runLoop {
            // Wake the loop so it notices the cancellation instead of sitting out its timeout.
            CFRunLoopStop(runLoop)
        }
    }

    /// Test hook: registers shortcuts without an event tap, then `feed` drives events directly.
    func configureForTesting(
        shortcuts: [ShortcutAction: Shortcut],
        interruptibleActions: Set<ShortcutAction> = [],
        onKeyDown: @escaping (ShortcutAction, TimeInterval) -> Void,
        onKeyUp: @escaping (ShortcutAction, TimeInterval) -> Void
    ) {
        teardownTap()
        stateLock.withLock {
            removeRegistrationLocked(owner: .testing)
            for (action, shortcut) in shortcuts {
                self.shortcuts[action] = ShortcutState(shortcut: shortcut)
                ownerByAction[action] = .testing
            }
            registrations[.testing] = Registration(
                interruptibleActions: interruptibleActions,
                onKeyDown: onKeyDown,
                onKeyUp: onKeyUp,
                onShortcutInterrupted: nil
            )
            self.interruptibleActions = interruptibleActions
        }
    }

    @discardableResult
    func feed(_ kind: EventKind, keyCode: UInt16, flags: NSEvent.ModifierFlags, at time: TimeInterval) -> Bool {
        handleEvent(kind: kind, keyCode: keyCode, modifierFlags: flags, eventTime: time)
    }

    private func installEventTap() -> Bool {
        guard !simulatesEventTapInstallFailure else { return false }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo,
                let monitor = Unmanaged<TapContext>.fromOpaque(userInfo).takeUnretainedValue().monitor
            else {
                return Unmanaged.passUnretained(event)
            }

            // Both kinds of disable go through the same budgeted re-arm. Nothing else rebuilds
            // the shared tap once it exists — register() sees a live tap and leaves it alone —
            // so leaving it off here would kill every shortcut until the app relaunches.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                monitor.handleTapDisabled(type)
                return Unmanaged.passUnretained(event)
            }

            let shouldSuppress = monitor.handleCGEvent(type: type, event: event)
            return shouldSuppress ? nil : Unmanaged.passUnretained(event)
        }

        guard
            let eventTap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: Self.eventMask,
                callback: callback,
                // Retained on purpose and never released: releasing it could free the box while
                // the tap thread is inside the callback holding it. One small box per install.
                userInfo: Unmanaged.passRetained(TapContext(monitor: self)).toOpaque()
            )
        else {
            logger.error("Failed to install global shortcut event tap")
            return false
        }

        // Immediately, before anything else can go wrong: tapCreate hands back an *enabled* tap,
        // so from the line above every keystroke on the machine is routed to a port that has no
        // run loop source yet. Anything between here and the disable is a system-wide stall.
        CGEvent.tapEnable(tap: eventTap, enable: false)

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            logger.error("Failed to create global shortcut event tap run loop source")
            return false
        }

        let generation = stateLock.withLock { () -> UInt64 in
            tapGeneration &+= 1
            self.eventTap = eventTap
            self.eventTapRunLoopSource = source
            self.tapReenableCount = 0
            self.tapReenableWindowStart = ProcessInfo.processInfo.systemUptime
            return tapGeneration
        }

        // Spin up the thread that owns the tap's run loop and wait for it to exist, so a
        // keystroke arriving immediately after start() has somewhere to be delivered.
        let thread = Thread { [weak self] in
            guard let self else { return }

            let runLoop = CFRunLoopGetCurrent()
            let isCurrentGeneration = self.stateLock.withLock { () -> Bool in
                guard self.tapGeneration == generation else { return false }
                self.tapRunLoop = runLoop
                return true
            }

            // A stop() beat us here; publishing this run loop would make a later stop() signal a
            // dead thread's loop and leak the live one.
            guard isCurrentGeneration, !Thread.current.isCancelled else { return }

            CFRunLoopAddSource(runLoop, source, .commonModes)
            // Last statement before the loop: nothing may sit between enabling the tap and
            // actually draining its port.
            CGEvent.tapEnable(tap: eventTap, enable: true)
            // Blocks until an event arrives or teardown calls CFRunLoopStop. The tap's source
            // keeps the loop alive, so this sleeps rather than polling — an earlier version ran
            // with a 0.5s timeout, which woke this thread twice a second for the life of the app
            // and cost battery for nothing. `.finished` means the loop has no sources left
            // (the port was invalidated under us), and re-entering it then would return at
            // once — spinning this userInteractive thread flat out. Exit instead.
            while !Thread.current.isCancelled {
                let result = CFRunLoopRunInMode(.defaultMode, .greatestFiniteMagnitude, false)
                if result == .finished || result == .stopped {
                    break
                }
            }
        }
        thread.name = "com.achyuthkp.voxos.shortcut-tap"
        // Keyboard delivery for the entire system waits on this thread; it must not be starved.
        thread.qualityOfService = .userInteractive
        stateLock.withLock { tapThread = thread }
        thread.start()

        // Deliberately not waiting here. The old blocking wait could hold the main thread for
        // two seconds, on a path driven by every @Published didSet, every shortcut edit and
        // every recorder-panel show — and a stalled main thread is precisely what makes the tap
        // time out, which is what used to spiral into a keyboard lockout. Check asynchronously
        // instead; the tap is disabled until the thread enables it, so the failure mode while
        // we wait is a dead shortcut, never a dead keyboard.
        verifyTapThreadStarted(generation: generation)

        return true
    }

    private func verifyTapThreadStarted(generation: UInt64) {
        retryScheduler(Self.tapStartVerificationDelay) { [weak self] in
            guard let self else { return }

            let hasStarted = self.stateLock.withLock {
                // A newer generation means this install was already replaced; not our problem.
                self.tapGeneration != generation || self.tapRunLoop != nil
            }

            guard !hasStarted else { return }

            self.logger.error("Shortcut event tap thread did not start; rebuilding")
            self.teardownTap()
            self.scheduleTapInstallRetry()
        }
    }

    private func handleCGEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard let eventKind = EventKind(type) else {
            return false
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifierFlags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue))
        // Runs on the tap thread. The whole transition is taken under one lock so a keystroke
        // never sees state half-written by start() or stop() on another thread. The handlers it
        // fires already hop to main, so nothing inside waits on the main thread — which is the
        // property that keeps system-wide typing responsive.
        //
        // Never *block* on that lock, though. This is an active head-inserted session tap, so
        // every keystroke on the machine passes through here: waiting on a lock that main holds
        // freezes typing everywhere until this process dies — which is what a wedged main thread
        // used to do. A contended lock costs at most one unrecognised shortcut; the event itself
        // is always passed through untouched.
        guard stateLock.try() else { return false }
        defer { stateLock.unlock() }

        return handleEvent(
            kind: eventKind,
            keyCode: keyCode,
            modifierFlags: modifierFlags,
            eventTime: ProcessInfo.processInfo.systemUptime
        )
    }

    /// A tap-disabled notification arrives on the tap thread, so this must never block: main
    /// takes `stateLock` in every start()/stop(), and waiting on it here stalls all typing on
    /// the machine. Skipping the cleanup only risks a stuck shortcut, which `start()` clears.
    private func releasePressedShortcutsAfterTapInterruption() {
        guard stateLock.try() else { return }
        defer { stateLock.unlock() }
        let eventTime = ProcessInfo.processInfo.systemUptime
        let pressedActions = shortcuts.compactMap { action, state in
            state.isDown ? action : nil
        }

        guard !pressedActions.isEmpty else {
            return
        }

        for action in pressedActions {
            if var state = shortcuts[action] {
                state.isDown = false
                state.pressedAt = nil
                state.isInterrupted = false
                shortcuts[action] = state
            }
            dispatchKeyUp(for: action, eventTime: eventTime)
        }
    }

    /// macOS disables the tap when its callback is too slow. Re-arming it unconditionally — as
    /// this used to — turns a transient stall into a lockout: the cause is still there, so the
    /// tap times out again, and each cycle swallows about a second of system-wide keyboard input
    /// for as long as the app runs. Re-arm a few times, then give up and tear the tap down. A
    /// dead shortcut is recoverable; a dead keyboard is not.
    private func handleTapDisabled(_ type: CGEventType) {
        releasePressedShortcutsAfterTapInterruption()

        // Runs on the tap thread, so never block on the lock. If main holds it right now, hand
        // the decision to main instead of skipping it: a skipped re-arm used to leave the tap
        // disabled for the rest of the session, because nothing else ever re-enables it.
        guard stateLock.try() else {
            DispatchQueue.main.async { [weak self] in
                self?.rearmOrRebuildTap(afterDisableOf: type)
            }
            return
        }

        let (tapToReenable, hasExceededBudget) = consumeReenableBudgetLocked()
        stateLock.unlock()

        applyTapDisableDecision(
            type: type, tapToReenable: tapToReenable, hasExceededBudget: hasExceededBudget)
    }

    /// Main-thread fallback for `handleTapDisabled` when the tap thread could not take the lock.
    private func rearmOrRebuildTap(afterDisableOf type: CGEventType) {
        let (tapToReenable, hasExceededBudget) = stateLock.withLock { consumeReenableBudgetLocked() }
        applyTapDisableDecision(
            type: type, tapToReenable: tapToReenable, hasExceededBudget: hasExceededBudget)
    }

    /// Caller must hold `stateLock`.
    private func consumeReenableBudgetLocked() -> (CFMachPort?, Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - tapReenableWindowStart > Self.tapReenableWindow {
            tapReenableWindowStart = now
            tapReenableCount = 0
        }
        tapReenableCount += 1
        let hasExceededBudget = tapReenableCount > Self.maxTapReenablesPerWindow
        return (hasExceededBudget ? nil : eventTap, hasExceededBudget)
    }

    private func applyTapDisableDecision(type: CGEventType, tapToReenable: CFMachPort?, hasExceededBudget: Bool) {
        guard !hasExceededBudget else {
            logger.error("Shortcut event tap keeps being disabled; rebuilding it on a backoff instead of re-arming")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.teardownTap()
                self.scheduleTapInstallRetry()
            }
            return
        }

        if let tapToReenable {
            if type == .tapDisabledByUserInput {
                logger.notice("Shortcut event tap disabled by user input; re-arming")
            }
            CGEvent.tapEnable(tap: tapToReenable, enable: true)
        }
    }

    private func handleEvent(
        kind: EventKind,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventTime: TimeInterval
    ) -> Bool {
        var shouldSuppress = false

        if kind == .keyDown {
            handleShortcutInterruptions(keyCode: keyCode, eventTime: eventTime)
        }

        for action in Array(shortcuts.keys) {
            guard var state = shortcuts[action] else {
                continue
            }

            if state.shortcut.isModifierOnly {
                handleModifierOnlyShortcut(
                    action: action,
                    state: state,
                    kind: kind,
                    keyCode: keyCode,
                    modifierFlags: modifierFlags,
                    eventTime: eventTime
                )
                continue
            }

            let transition = transitionForKeyShortcut(
                state.shortcut,
                isDown: state.isDown,
                kind: kind,
                keyCode: keyCode,
                modifierFlags: modifierFlags
            )

            switch transition {
            case .none:
                break
            case .suppress:
                shouldSuppress = true
            case .keyDown:
                state.isDown = true
                state.pressedAt = eventTime
                state.isInterrupted = false
                shortcuts[action] = state
                shouldSuppress = true
                dispatchKeyDown(for: action, eventTime: eventTime)
            case .keyUp:
                state.isDown = false
                state.pressedAt = nil
                state.isInterrupted = false
                shortcuts[action] = state
                shouldSuppress = true
                dispatchKeyUp(for: action, eventTime: eventTime)
            }
        }

        return shouldSuppress
    }

    private enum ShortcutTransition {
        case none
        case suppress
        case keyDown
        case keyUp
    }

    private func transitionForKeyShortcut(
        _ shortcut: Shortcut,
        isDown: Bool,
        kind: EventKind,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags
    ) -> ShortcutTransition {
        switch kind {
        case .keyDown:
            guard shortcut.matchesKeyEvent(keyCode: keyCode, modifierFlags: modifierFlags) else {
                return .none
            }

            return isDown ? .suppress : .keyDown
        case .keyUp:
            return isDown && keyCode == shortcut.keyCode ? .keyUp : .none
        case .flagsChanged:
            guard isDown else {
                return .none
            }

            let currentFlags = Shortcut.normalizedModifierFlags(
                modifierFlags,
                forKeyCode: shortcut.keyCode
            )
            return currentFlags.isSuperset(of: shortcut.modifierFlags) ? .suppress : .keyUp
        }
    }

    private func handleModifierOnlyShortcut(
        action: ShortcutAction,
        state: ShortcutState,
        kind: EventKind,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        eventTime: TimeInterval
    ) {
        var state = state

        guard kind == .flagsChanged else {
            return
        }

        if state.isDown {
            if state.shortcut.shouldReleaseModifierEvent(keyCode: keyCode, modifierFlags: modifierFlags) {
                state.isDown = false
                state.pressedAt = nil
                state.isInterrupted = false
                shortcuts[action] = state
                dispatchKeyUp(for: action, eventTime: eventTime)
            }

            return
        }

        if state.shortcut.matchesModifierEvent(keyCode: keyCode, modifierFlags: modifierFlags) {
            state.isDown = true
            state.pressedAt = eventTime
            state.isInterrupted = false
            shortcuts[action] = state
            dispatchKeyDown(for: action, eventTime: eventTime)
        }
    }

    private func handleShortcutInterruptions(keyCode: UInt16, eventTime: TimeInterval) {
        guard !Shortcut.isModifierKeyCode(keyCode) else {
            return
        }

        for action in interruptibleActions {
            guard var state = shortcuts[action],
                state.isDown,
                !state.isInterrupted,
                let pressedAt = state.pressedAt,
                eventTime - pressedAt <= Self.shortcutInterruptionWindow,
                state.shortcut.isInterruptedByAdditionalKeyDown(keyCode: keyCode)
            else {
                continue
            }

            state.isInterrupted = true
            shortcuts[action] = state
            dispatchShortcutInterrupted(for: action, eventTime: eventTime)
        }
    }

    /// Caller holds `stateLock`; the handler itself runs on main, never under the lock.
    private func registration(for action: ShortcutAction) -> Registration? {
        ownerByAction[action].flatMap { registrations[$0] }
    }

    private func dispatchKeyDown(for action: ShortcutAction, eventTime: TimeInterval) {
        guard let handler = registration(for: action)?.onKeyDown else { return }
        DispatchQueue.main.async {
            handler(action, eventTime)
        }
    }

    private func dispatchKeyUp(for action: ShortcutAction, eventTime: TimeInterval) {
        guard let handler = registration(for: action)?.onKeyUp else { return }
        DispatchQueue.main.async {
            handler(action, eventTime)
        }
    }

    private func dispatchShortcutInterrupted(for action: ShortcutAction, eventTime: TimeInterval) {
        guard let handler = registration(for: action)?.onShortcutInterrupted else { return }
        DispatchQueue.main.async {
            handler(action, eventTime)
        }
    }

    private static let eventMask: CGEventMask = [
        CGEventType.keyDown,
        CGEventType.keyUp,
        CGEventType.flagsChanged,
    ].reduce(CGEventMask(0)) { mask, type in
        mask | (CGEventMask(1) << Int(type.rawValue))
    }
}

extension ShortcutMonitor.EventKind {
    init?(_ type: CGEventType) {
        switch type {
        case .keyDown:
            self = .keyDown
        case .keyUp:
            self = .keyUp
        case .flagsChanged:
            self = .flagsChanged
        default:
            return nil
        }
    }
}
