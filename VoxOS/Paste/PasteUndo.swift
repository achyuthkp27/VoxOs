import AppKit
import Carbon.HIToolbox
import os

/// Takes back the text VoxOS just pasted, from the Undo Last Paste shortcut or by saying
/// "scratch that".
///
/// It presses ⌘Z in the app the text went into, which undoes the paste the way the app itself
/// would, keeping whatever the user typed before it. To be sure that ⌘Z lands on the paste, it
/// only does so while that app is still in front, for a short while after the paste, and once.
@MainActor
enum PasteUndo {
    private static let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "PasteUndo")

    /// How long after a paste it can still be undone.
    nonisolated static let window: TimeInterval = 120

    private static var lastPaste: (pid: pid_t, at: Date)?

    /// Notes a paste into the app now in front.
    static func recordPaste(now: Date = Date()) {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
            pid != ProcessInfo.processInfo.processIdentifier
        else { return }
        lastPaste = (pid, now)
    }

    /// Whether ⌘Z would land on the paste: same app still in front, recent enough.
    nonisolated static func canUndo(pastedInto pid: pid_t?, at pastedAt: Date?, frontmost: pid_t?, now: Date) -> Bool {
        guard let pid, let pastedAt, let frontmost else { return false }
        return pid == frontmost && now.timeIntervalSince(pastedAt) >= 0 && now.timeIntervalSince(pastedAt) <= window
    }

    /// Undoes the last paste when it safely can; otherwise says why not. Returns whether it did.
    @discardableResult
    static func undoLastPaste(now: Date = Date()) -> Bool {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard canUndo(pastedInto: lastPaste?.pid, at: lastPaste?.at, frontmost: frontmost, now: now) else {
            NotificationManager.shared.showNotification(
                title: String(localized: "Nothing to undo — the last paste was in another app or a while ago."),
                type: .info)
            return false
        }
        lastPaste = nil
        postCommandZ()
        logger.info("Undid the last paste")
        return true
    }

    /// ⌘Z, sent the way the paste sends ⌘V: the same event source, 10 ms between events.
    private static func postCommandZ() {
        guard AXIsProcessTrusted() else {
            logger.error("Accessibility permission is required to undo with a simulated ⌘Z")
            return
        }
        let source = CGEventSource(stateID: .privateState)
        let z = CGKeyCode(kVK_ANSI_Z)
        let command = CGKeyCode(kVK_Command)
        guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: true),
            let zDown = CGEvent(keyboardEventSource: source, virtualKey: z, keyDown: true),
            let zUp = CGEvent(keyboardEventSource: source, virtualKey: z, keyDown: false),
            let commandUp = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: false)
        else { return }
        commandDown.flags = .maskCommand
        zDown.flags = .maskCommand
        zUp.flags = .maskCommand
        Task { @MainActor in
            for event in [commandDown, zDown, zUp, commandUp] {
                event.post(tap: .cghidEventTap)
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}
