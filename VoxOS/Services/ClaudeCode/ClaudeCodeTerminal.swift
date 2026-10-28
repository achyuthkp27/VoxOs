import AppKit
import Darwin

/// The app a Claude Code session runs in: the nearest ancestor of its CLI that is a regular app
/// (Terminal, iTerm2, Ghostty, cmux, an editor with a terminal). Measured on 2.1.312 under cmux:
/// CLI → zsh → login → cmux. A CLI under tmux or ssh has no such ancestor on this Mac, so its
/// requests always get the card.
enum ClaudeCodeTerminal {
    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }

    @MainActor
    static func app(
        hosting cliPID: pid_t, parentOf: (pid_t) -> pid_t? = ClaudeCodeTerminal.parent(of:),
        isApp: (pid_t) -> Bool = { NSRunningApplication(processIdentifier: $0)?.activationPolicy == .regular }
    ) -> pid_t? {
        var pid: pid_t? = cliPID
        // Deep enough for any terminal's helpers and shells; a loop in the table cannot hang it.
        for _ in 0..<32 {
            guard let current = pid else { return nil }
            if isApp(current) { return current }
            pid = parentOf(current)
        }
        return nil
    }
}
