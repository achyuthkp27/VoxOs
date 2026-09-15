import Foundation

/// What the Agent is doing right now, shown in the recorder instead of a static "Thinking",
/// so a slow model or a rate-limit wait never looks like a frozen app.
@MainActor
final class AgentProgress: ObservableObject {
    static let shared = AgentProgress()

    @Published private(set) var status: String?

    nonisolated static func set(_ status: String?) {
        Task { @MainActor in shared.status = status }
    }

    nonisolated static func label(forTool tool: String) -> String {
        if tool.hasPrefix(AgentMCP.toolPrefix) {
            let server = tool.dropFirst(AgentMCP.toolPrefix.count).split(separator: "_").first.map(String.init) ?? "server"
            return "Asking \(server)…"
        }
        if tool.hasPrefix("plugin_") { return "Running a plugin…" }
        switch tool {
        case "open_app", "activate_app": return "Opening the app…"
        case "open_url", "web_search": return "Opening the page…"
        case "read_screen", "find_text", "list_ui_elements", "element_under_cursor", "mark_screen", "see_screen":
            return "Looking at the screen…"
        case "click_element", "click_text", "click_mark", "mouse_click", "browser_click_text": return "Clicking…"
        case "type_text", "press_key", "hotkey": return "Typing…"
        case "run_shell", "run_applescript": return "Running a command…"
        case "fetch_url", "web_results", "browser_snapshot": return "Reading the web…"
        case "search_everywhere", "find_files", "gmail_search": return "Searching…"
        case "wait", "wait_for_text": return "Waiting for the screen…"
        case "calendar_add_event", "calendar_today", "calendar_upcoming": return "Checking your calendar…"
        case "reminders_add", "reminders_list": return "Updating reminders…"
        case "mail_compose", "gmail_compose", "slack_send", "messages_send", "whatsapp_send", "telegram_send":
            return "Writing the message…"
        default: return "Working…"
        }
    }
}
