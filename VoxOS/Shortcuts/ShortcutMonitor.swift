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

    private var shortcuts: [ShortcutAction: ShortcutState] = [:]
    private var interruptibleActions: Set<ShortcutAction> = []
    private var onKeyDown: ((ShortcutAction, TimeInterval) -> Void)?
    private var onKeyUp: ((ShortcutAction, TimeInterval) -> Void)?
    private var onShortcutInterrupted: ((ShortcutAction, TimeInterval) -> Void)?
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
    private let tapReady = DispatchSemaphore(value: 0)

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
    var retryScheduler: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static let shortcutInterruptionWindow: TimeInterval = 1.0
    private static let initialTapRetryDelay: TimeInterval = 1.0
    private static let maxTapRetryDelay: TimeInterval = 30.0

    deinit {
        stop()
    }

    @discardableResult
    func start(
        shortcuts: [ShortcutAction: Shortcut],
        interruptibleActions: Set<ShortcutAction> = [],
        onKeyDown: @escaping (ShortcutAction, TimeInterval) -> Void,
        onKeyUp: @escaping (ShortcutAction, TimeInterval) -> Void,
        onShortcutInterrupted: ((ShortcutAction, TimeInterval) -> Void)? = nil
    ) -> Bool {
        stop()

        // One atomic setup: the tap is installed last, so it can never observe a partly
        // configured monitor.
        let hasShortcuts = stateLock.withLock { () -> Bool in
            for (action, shortcut) in shortcuts {
                self.shortcuts[action] = ShortcutState(shortcut: shortcut)
            }
            guard !self.shortcuts.isEmpty else { return false }

            self.interruptibleActions = interruptibleActions
            self.onKeyDown = onKeyDown
            self.onKeyUp = onKeyUp
            self.onShortcutInterrupted = onShortcutInterrupted
            return true
        }

        guard hasShortcuts else { return true }

        return installEventTapOrScheduleRetry()
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
                self.tapRetryGeneration == generation && !self.shortcuts.isEmpty
            }

            guard isRetryCurrent, self.eventTap == nil else { return }

            self.installEventTapOrScheduleRetry()
        }
    }

    func stop() {
        if let eventTapRunLoopSource, let tapRunLoop {
            CFRunLoopRemoveSource(tapRunLoop, eventTapRunLoopSource, .commonModes)
        }
        eventTapRunLoopSource = nil

        if let eventTap {
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }

        tapThread?.cancel()
        if let tapRunLoop {
            // Wake the loop so it notices the cancellation instead of sitting out its timeout.
            CFRunLoopStop(tapRunLoop)
        }
        tapThread = nil
        tapRunLoop = nil

        stateLock.withLock {
            shortcuts = [:]
            interruptibleActions = []
            onKeyDown = nil
            onKeyUp = nil
            onShortcutInterrupted = nil
            tapRetryGeneration &+= 1
            tapRetryDelay = Self.initialTapRetryDelay
        }
    }

    /// Test hook: registers shortcuts without an event tap, then `feed` drives events directly.
    func configureForTesting(
        shortcuts: [ShortcutAction: Shortcut],
        interruptibleActions: Set<ShortcutAction> = [],
        onKeyDown: @escaping (ShortcutAction, TimeInterval) -> Void,
        onKeyUp: @escaping (ShortcutAction, TimeInterval) -> Void
    ) {
        stop()
        for (action, shortcut) in shortcuts { self.shortcuts[action] = ShortcutState(shortcut: shortcut) }
        self.interruptibleActions = interruptibleActions
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp
    }

    @discardableResult
    func feed(_ kind: EventKind, keyCode: UInt16, flags: NSEvent.ModifierFlags, at time: TimeInterval) -> Bool {
        handleEvent(kind: kind, keyCode: keyCode, modifierFlags: flags, eventTime: time)
    }

    private func installEventTap() -> Bool {
        guard !simulatesEventTapInstallFailure else { return false }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                monitor.resetPressedShortcutsAfterTapInterruption()
                if let eventTap = monitor.eventTap {
                    CGEvent.tapEnable(tap: eventTap, enable: true)
                }
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
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            logger.error("Failed to install global shortcut event tap")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            logger.error("Failed to create global shortcut event tap run loop source")
            return false
        }

        // tapCreate returns an *enabled* tap, so from this instant every keystroke on the machine
        // is routed to a mach port that nothing is servicing yet — input stalls until the tap
        // thread's run loop picks the source up. Keep it off until that is true.
        CGEvent.tapEnable(tap: eventTap, enable: false)

        self.eventTap = eventTap
        eventTapRunLoopSource = source

        // Spin up the thread that owns the tap's run loop and wait for it to exist, so a
        // keystroke arriving immediately after start() has somewhere to be delivered.
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.tapRunLoop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
            self.tapReady.signal()
            // Blocks until an event arrives or stop() calls CFRunLoopStop. The tap's source
            // keeps the loop alive, so this sleeps rather than polling — an earlier version ran
            // with a 0.5s timeout, which woke this thread twice a second for the life of the app
            // and cost battery for nothing. The outer loop only covers CFRunLoopRun returning
            // because every source went away.
            while !Thread.current.isCancelled {
                CFRunLoopRun()
            }
        }
        thread.name = "com.achyuthkp.voxos.shortcut-tap"
        // Keyboard delivery for the entire system waits on this thread; it must not be starved.
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()

        // Bounded: if the thread cannot start, fall through rather than hanging the caller.
        _ = tapReady.wait(timeout: .now() + 2)
        return true
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

    private func resetPressedShortcutsAfterTapInterruption() {
        stateLock.lock()
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

    private func dispatchKeyDown(for action: ShortcutAction, eventTime: TimeInterval) {
        DispatchQueue.main.async { [onKeyDown] in
            onKeyDown?(action, eventTime)
        }
    }

    private func dispatchKeyUp(for action: ShortcutAction, eventTime: TimeInterval) {
        DispatchQueue.main.async { [onKeyUp] in
            onKeyUp?(action, eventTime)
        }
    }

    private func dispatchShortcutInterrupted(for action: ShortcutAction, eventTime: TimeInterval) {
        DispatchQueue.main.async { [onShortcutInterrupted] in
            onShortcutInterrupted?(action, eventTime)
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
