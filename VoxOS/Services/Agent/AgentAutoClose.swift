import Foundation

/// Closes the Agent panel by itself after a request that only launched something.
///
/// The reply panel stays open on purpose, so a spoken answer can be followed up. For "open Slack"
/// there is nothing to follow up on, and leaving "Opened Slack." on screen reads as the Agent
/// hanging. A run closes itself only when everything it did was a launch that worked: any other
/// tool, any error, a confirmation or a question keeps the panel up so the user sees it.
enum AgentAutoClose {
    static let enabledKey = DefaultsKeys.agentAutoCloseAfterOpen
    /// Long enough to read "Opened Slack." and see the app arrive; short enough not to feel stuck.
    static let delay: TimeInterval = 1.2

    /// Tools whose whole job is to bring something up. `wait` is allowed so "open X and give it a
    /// second" still counts; anything that reads, clicks, types or sends does not.
    static let launchTools: Set<String> = [
        "open_app", "activate_app", "open_url", "open_in_editor", "maps_search", "maps_directions", "wait",
    ]

    private static let lock = NSLock()
    private static var launched = false
    private static var disqualified = false

    /// A new foreground request starts clean, whatever the previous one did.
    static func beginRun() {
        lock.lock()
        defer { lock.unlock() }
        launched = false
        disqualified = false
    }

    /// Records a finished tool call. Background tasks have no panel, so they never count.
    static func record(tool: String, result: [String: Any]) {
        guard !AgentRunScope.isBackground else { return }
        lock.lock()
        defer { lock.unlock() }
        if isCleanLaunch(tool: tool, result: result) {
            if tool != "wait" { launched = true }
        } else {
            disqualified = true
        }
    }

    /// The deterministic "open <app>" path never reaches the tool loop.
    static func recordQuickLaunch() {
        guard !AgentRunScope.isBackground else { return }
        lock.lock()
        defer { lock.unlock() }
        launched = true
    }

    /// True once if the run that just finished only launched things. Clears the record.
    static func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        defer {
            launched = false
            disqualified = false
        }
        return launched && !disqualified
    }

    static func isCleanLaunch(tool: String, result: [String: Any]) -> Bool {
        guard launchTools.contains(tool) else { return false }
        // `error` is a failure to show; `confirm_required` and `question` need the user to answer.
        return result["error"] == nil && result["confirm_required"] == nil && result["question"] == nil
    }

    /// Whether to dismiss when the delay is up. Anything that changed in the meantime wins: if
    /// the user started talking again, or the reply was replaced, the panel is theirs now.
    static func shouldDismiss(
        armed: Bool, settingEnabled: Bool, recorderIdle: Bool, sessionUnchanged: Bool
    ) -> Bool {
        armed && settingEnabled && recorderIdle && sessionUnchanged
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
}
