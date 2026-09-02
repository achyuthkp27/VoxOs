import Foundation

/// The computer-control and system tools, described for the model. Injected into the
/// agent system prompt at request time (see AIEnhancementService.getSystemMessage) so it
/// stays in sync with the code and reaches installs whose seeded Agent prompt predates it.
enum AgentToolCatalog {

    static let promptSection = """
        # Computer control tools
        Coordinates everywhere are GLOBAL screen points with a top-left origin — a value from list_ui_elements, find_text or list_windows can be passed straight to mouse_click.
        Prefer the cheapest reliable path: click_element (Accessibility, no pixels) → click_text (OCR) → mark_screen + click_mark → mouse_click at coordinates as a last resort.

        ## See the screen
        - read_screen {} -> all visible text on the user's display (OCR) plus the frontmost app. Use this to answer "what's on my screen" or before acting on unfamiliar UI.
        - find_text {"query": str} -> where a piece of text is on screen (centre x/y). Empty query lists everything.
        - list_ui_elements {} -> buttons, fields, links, menu items of the frontmost app with titles and centre points.
        - mark_screen {} -> draws numbered badges on every clickable region ON THE USER'S SCREEN for 30s and returns each number's label. Use when nothing has a clear name: tell the user the numbers are showing and ask which one, or pick by label. Then click_mark.

        ## Click, type, keys
        - click_element {"name": str, "role": str?, "count": int?} -> presses the UI element whose title best matches name (via Accessibility). Best for buttons, menu items, checkboxes, links.
        - click_text {"query": str, "match_index": int?} -> clicks visible text found by OCR.
        - click_mark {"mark": int} -> clicks a numbered badge from mark_screen.
        - mouse_click {"x": num, "y": num, "button": "left"|"right"?, "count": int?}
        - mouse_move {"x": num, "y": num} · mouse_drag {"from_x", "from_y", "to_x", "to_y", "duration_ms"?}
        - scroll {"delta_y": int, "delta_x": int?, "x": num?, "y": num?} -> negative delta_y scrolls down. Move to x/y first if given.
        - press_key {"key": str, "modifiers": [str]?} -> key is return, tab, escape, space, delete, up/down/left/right, home, end, pageup, pagedown, f1–f12, or a single character. modifiers: cmd, shift, option, control.
        - hotkey {"keys": [str]} -> e.g. ["cmd","shift","4"].
        - undo_last_action {} -> sends ⌘Z to the frontmost app. Use when the user says "undo that" or "that wasn't me".
        - type_text is the existing tool; it pastes at the cursor.

        ## Sequencing
        - wait {"seconds": num} -> pause up to 30s for the UI to settle.
        - wait_for_text {"text": str, "timeout_seconds": int?} -> block until text appears on screen (max 60s). Use after opening apps or pages.
        - batch_actions {"actions": [{"tool": str, "args": {...}}], "stop_on_error": bool?, "dry_run": bool?} -> run several steps in one call. dry_run only reports what would run.

        ## Apps & windows
        - frontmost_app {} · list_apps {} · activate_app {"name": str} -> bring a running app to the front (open_app launches it if not running).
        - list_windows {} -> on-screen windows with app, title and bounds.
        - set_window_bounds {"app": str, "x": num, "y": num, "width": num, "height": num}

        ## Shell, scripts, files
        - run_shell {"command": str} -> runs in zsh, 30s limit. Risky commands are blocked unless the user enabled them in Settings → Agent. Use this for anything with no dedicated tool.
        - run_applescript {"script": str}
        - read_file {"path": str} -> text files, code, directories (lists entries). ~ is expanded.
        - read_pdf {"path": str} -> extracts PDF text.
        - move_file {"from": str, "to": str} -> move or rename. There is deliberately no delete.
        - read_clipboard {} -> what the user last copied.

        ## Browser
        - browser_snapshot {} -> the frontmost tab's URL, title and clickable elements. Requires "Allow JavaScript from Apple Events" in the browser's Develop menu.
        - browser_click_text {"text": str} -> clicks the page element whose text matches, directly in the DOM.
        - browser_run_js {"js": str} -> runs JavaScript in the frontmost tab and returns the result.
        - list_browser_tabs {} · switch_browser_tab {"index": int}
        - fetch_url {"url": str} -> the page's text, without opening a browser. Prefer this for reading.
        - web_results {"query": str} -> search results (title, url, snippet) as text. web_search opens the browser instead.

        ## Macros — teach it a skill
        - macro_record_start {"name": str} -> from now on every action is captured. Then the user performs the steps by voice.
        - macro_record_stop {} -> saves it. macro_run {"name": str} replays it. macro_list {} · macro_delete {"name": str}

        ## Plugins — extend yourself
        - plugin_list {} -> user-installed tools; they appear in this prompt as plugin_*.
        - plugin_create {"name": str, "description": str, "run_type": "shell"|"applescript"|"open_url", "template": str, "parameters": {"arg": "description"}} -> writes a new tool. Use {{arg}} placeholders in template. It becomes callable on the next request.
        - plugin_delete {"name": str}

        ## System audio (what the Mac is playing — never the mic)
        - system_audio_start {} -> start capturing speaker output (a video, a call, music). system_audio_stop {} -> stop and get the transcript. Use when the user says "listen to this", "record what's playing", "transcribe this video".
        - system_audio_recall {"seconds": int?} -> transcript of the last N seconds from the rolling buffer (needs "Keep Recent System Audio" on). Use for "what did they just say?".
        - watch_for_audio {"text": str, "timeout_seconds": int?} -> notify the user when that phrase is heard in system audio.

        ## Pause for the user
        - wait_for_user {"question": str, "context": str?} -> when you cannot continue without an answer (which file, which contact, confirm a choice). Then end your reply with the question. The next request is the answer and the context comes back to you.

        ## Learning a language
        - set_learning_language {"language": str} -> the user is learning this language; explain words and phrases they hear or read in it. "off" to stop.
        - mark_vocabulary_known {"word": str} -> the user knows this word; it is added to their custom vocabulary so dictation spells it right.

        ## Ambient & modes
        - watch_for {"text": str, "timeout_seconds": int?} -> notify the user when text appears on screen (checks every few seconds, up to an hour). watch_list {} · watch_cancel {"watch_id": str?}
        - set_control_mode {"mode": "takeover"|"ask_before_action"|"observe_only"} -> how freely you may act. In ask_before_action every mutating tool returns confirm_required first. get_control_mode {}

        ## Diagnostics & secrets
        - permissions_diagnostics {} -> which macOS permissions are granted. Call this when a click or screen tool fails.
        - system_status {} -> battery, free disk, memory, uptime, thermal state.
        - secret_save {"name": str, "value": str} -> store a token in the Keychain. secret_exists {"name": str}

        # Computer-control rules
        - After activating an app or opening a page, wait_for_text (or wait) before clicking into it.
        - When an action fails, look before retrying: read_screen or list_ui_elements, then choose a different path down the fallback chain.
        - Never guess coordinates. Get them from list_ui_elements, find_text or list_windows.
        - Say what you did in the final sentence, including anything that was blocked or needs a permission.
        """

    /// Live state appended after the catalogue: control mode, plugins, active macro recording.
    static func runtimeSection() -> String {
        var lines: [String] = ["# Agent state", "- control mode: \(AgentControlMode.current.rawValue) — \(AgentControlMode.current.summary)"]
        if let paused = AgentPausedTask.take() {
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
        return lines.joined(separator: "\n")
    }
}
