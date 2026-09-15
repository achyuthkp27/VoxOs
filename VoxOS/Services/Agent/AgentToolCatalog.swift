import Foundation

/// The computer-control and system tools, described for the model. Injected into the
/// agent system prompt at request time (see AIEnhancementService.getSystemMessage) so it
/// stays in sync with the code and reaches installs whose seeded Agent prompt predates it.
enum AgentToolCatalog {

    static let promptSection = """
        # Computer tools
        Coordinates are global screen points, top-left origin; values from list_ui_elements, find_text, list_windows pass straight to mouse_click. Cheapest reliable path first: click_element → click_text → mark_screen+click_mark → mouse_click.
        Screen: - read_screen {} -> visible text + frontmost app · - find_text {"query": str} -> text centre x/y · - list_ui_elements {} -> buttons/fields/links with centres · - element_under_cursor {} -> element under the pointer (also given as ELEMENT_UNDER_CURSOR; "this"/"that"/"it" means it) · - mark_screen {} -> numbered badges on clickables for 30s
        Act: - click_element {"name": str, "role": str?, "count": int?} · - click_text {"query": str, "match_index": int?} · - click_mark {"mark": int} · - mouse_click {"x": num, "y": num, "button": "left"|"right"?, "count": int?} · mouse_move {"x","y"} · mouse_drag {"from_x","from_y","to_x","to_y","duration_ms"?} · scroll {"delta_y": int, "delta_x": int?, "x"?, "y"?} (negative = down) · - press_key {"key": str, "modifiers": [cmd|shift|option|control]?} · - hotkey {"keys": [str]} · undo_last_action {} (⌘Z) · type_text pastes at the cursor
        Flow: wait {"seconds": num≤30} · - wait_for_text {"text": str, "timeout_seconds": int?} · - batch_actions {"actions": [{"tool", "args"}], "stop_on_error": bool?, "dry_run": bool?}
        Apps: frontmost_app {} · list_apps {} · activate_app {"name"} (open_app launches) · list_windows {} · set_window_bounds {"app","x","y","width","height"}
        System: - run_shell {"command": str} (zsh, 30s; risky blocked unless allowed) · - run_applescript {"script": str} · - read_file {"path": str} · read_pdf {"path"} · move_file {"from","to"} (no delete) · read_clipboard {}
        Browser: browser_snapshot {} · browser_click_text {"text"} · browser_run_js {"js"} · list_browser_tabs {} · switch_browser_tab {"index"} · - fetch_url {"url": str} (read a page without the browser) · web_results {"query"} (web_search opens the browser)
        Find: search_everywhere {"query"} -> Finder + connected MCP sources; use when the user doesn't say where · mcp_servers {}
        Apps by link: obsidian_note {"name","content"?,"vault"?,"append"?} · open_in_editor {"path","editor": "vscode"|"cursor"?,"line"?} · maps_search {"query"} · maps_directions {"to","from"?,"mode"?} · telegram_send {"to"?,"text"} (user presses Send)
        Sending: mail_compose, gmail_compose, slack_send take "send": true only when the user said send; that returns confirm_required — say what goes to whom and stop. Next request: confirm → confirm_action {}, declined → cancel_action {}. Otherwise leave a draft.
        Macros: macro_record_start {"name"} · macro_record_stop {} · - macro_run {"name": str} · macro_list {} · macro_delete {"name"}
        Plugins: plugin_list {} · - plugin_create {"name","description","run_type": "shell"|"applescript"|"open_url","template" ({{arg}}),"parameters"} · plugin_delete {"name"}
        Audio (speaker output, never mic): - system_audio_start {} · system_audio_stop {} -> transcript · - system_audio_recall {"seconds"?} · watch_for_audio {"text","timeout_seconds"?}
        Ask: - wait_for_user {"question": str, "context": str?} -> then end your reply with the question
        Language: - set_learning_language {"language"|"off"} · mark_vocabulary_known {"word"}
        Ambient: - watch_for {"text": str, "timeout_seconds": int?} · watch_list {} · watch_cancel {"watch_id"?} · - set_control_mode {"mode": "takeover"|"ask_before_action"|"observe_only"} · get_control_mode {}
        Diagnostics: permissions_diagnostics {} (call when clicks/screen fail) · system_status {} · secret_save {"name","value"} · secret_exists {"name"}

        # Rules
        - After opening an app or page, wait_for_text before clicking. On failure, look (read_screen/list_ui_elements) and take a different path; never guess coordinates.
        - Answer the question; never narrate tools. "What is this?" = describe what's under the cursor or on screen in 1–2 sentences. "What can you do?" = a few concrete examples.
        - Act when the request is clear. If an app isn't found, say so and suggest the closest names instead of retrying.
        - Final reply: one or two plain sentences on what you did, including anything blocked.
        """

    /// Live state appended after the catalogue: control mode, plugins, active macro recording.
    static func runtimeSection() -> String {
        var lines: [String] = ["# Agent state", "- control mode: \(AgentControlMode.current.rawValue) — \(AgentControlMode.current.summary)"]
        if let paused = AgentPausedTask.peek() {
            lines.append("- RESUMING a paused task. You asked the user: \"\(paused.question)\". Treat <TRANSCRIPT> as their answer and continue the task." + (paused.context.isEmpty ? "" : " Context: \(paused.context)"))
        }
        if let language = UserDefaults.standard.string(forKey: "agentLearningLanguage"), !language.isEmpty {
            lines.append("- learning language: \(language). When the user asks about a word or phrase, explain it in that language's context (meaning, usage, one example). Call mark_vocabulary_known when they say they know it.")
        }
        if let name = AgentMacros.recordingName {
            lines.append("- RECORDING macro \"\(name)\": every mutating tool call is being captured until macro_record_stop.")
        }
        let macros = AgentMacros.list()
        if !macros.isEmpty {
            lines.append("- saved macros: " + macros.map(\.name).joined(separator: ", "))
        }
        let plugins = AgentPlugins.promptLines()
        if !plugins.isEmpty {
            lines.append("")
            lines.append("# Installed plugin tools")
            lines.append(contentsOf: plugins)
        }
        if let mcp = AgentMCP.promptSection() {
            lines.append("")
            lines.append(mcp)
        }
        return lines.joined(separator: "\n")
    }
}
