import Foundation

/// Engine handle for tools that need the data store (vocabulary, history).
@MainActor
enum AgentEnvironment {
    static weak var engine: VoxOSEngine?
}

/// A task the agent paused with `wait_for_user`; surfaced in the next prompt, then cleared.
enum AgentPausedTask {
    struct Paused: Equatable {
        let id: UUID
        let question: String
        let context: String
    }

    private static let lock = NSLock()
    private static var pending: Paused?

    static func set(question: String, context: String) {
        lock.lock(); defer { lock.unlock() }
        pending = Paused(id: UUID(), question: question, context: context)
    }

    static func peek() -> Paused? {
        lock.lock(); defer { lock.unlock() }
        return pending
    }

    /// Clears only the task that was resumed — never one the current run just created.
    static func clear(resumed id: UUID?) {
        lock.lock(); defer { lock.unlock() }
        guard let id, pending?.id == id else { return }
        pending = nil
    }
}

/// How much the agent is allowed to do on its own. Mirrors Samuel's control modes.
/// - `takeover`: act freely (default).
/// - `askBeforeAction`: any tool that changes the Mac is held until the user says "confirm".
/// - `observeOnly`: mutating tools are refused; the agent can still look, read and answer.
enum AgentControlMode: String, CaseIterable, Identifiable {
    case takeover
    case askBeforeAction = "ask_before_action"
    case observeOnly = "observe_only"

    static let userDefaultsKey = "agentControlMode"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .takeover: return String(localized: "Act freely")
        case .askBeforeAction: return String(localized: "Ask before acting")
        case .observeOnly: return String(localized: "Observe only")
        }
    }

    var summary: String {
        switch self {
        case .takeover: return String(localized: "Clicks, types and runs commands without asking.")
        case .askBeforeAction: return String(localized: "Describes each action and waits for you to say “confirm”.")
        case .observeOnly: return String(localized: "Can read the screen and answer, but never acts.")
        }
    }

    static var current: AgentControlMode {
        get { AgentControlMode(rawValue: UserDefaults.standard.string(forKey: userDefaultsKey) ?? "") ?? .takeover }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: userDefaultsKey) }
    }

    /// Tools that change the Mac or the outside world. Everything else is read-only and
    /// always runs, so the agent can still observe and plan in any mode.
    static let mutatingTools: Set<String> = [
        "click_element", "click_text", "click_mark", "mouse_click", "mouse_move", "mouse_drag", "scroll",
        "type_text", "press_key", "hotkey", "undo_last_action", "batch_actions",
        "run_shell", "run_applescript", "open_url", "open_app", "activate_app", "set_window_bounds",
        "calendar_add_event", "reminders_add", "notes_create", "mail_compose",
        "browser_click_text", "browser_run_js", "switch_browser_tab",
        "clipboard_write", "move_file", "read_file", "read_pdf", "macro_run", "macro_delete", "plugin_create", "plugin_delete",
        "whatsapp_send", "gmail_compose", "slack_send", "linear_create_issue",
        "system_volume", "lock_screen", "media_key",
        "system_audio_start", "system_audio_stop",
        "set_control_mode", "messages_send", "secret_save", "linear_save_token", "remember", "take_screenshot",
        "macro_record_start", "macro_record_stop", "watch_for", "watch_for_audio", "watch_cancel",
        "set_learning_language", "mark_vocabulary_known",
    ]

    static func isMutating(_ tool: String) -> Bool {
        mutatingTools.contains(tool) || (AgentPlugins.isPlugin(tool) && tool != "plugin_list")
    }
}
