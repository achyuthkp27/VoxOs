import AppKit
import AVFoundation
import Foundation
import Speech
import SwiftData

/// Entry point for every tool call. Applies the control-mode gate, records macro steps,
/// and routes to the computer-control / system tools ported from cursor-voice, falling back
/// to the app-integration tools in `AgentTools.executeBuiltin`.
extension AgentTools {

    static func execute(name: String, args: [String: Any]) async -> [String: Any] {
        // Confirmation flow is exempt from gating — it IS the gate.
        if name == "confirm_action" { return await confirmPending() }
        if name == "cancel_action" {
            AgentPendingAction.clear()
            return ["result": "pending action canceled"]
        }

        if AgentControlMode.isMutating(name) {
            switch AgentControlMode.current {
            case .observeOnly:
                return [
                    "error": "blocked: the agent is in observe-only mode and cannot \(name). The user can switch modes in Settings → Agent or by saying “act freely”.",
                ]
            case .askBeforeAction where !alwaysConfirms(name):
                AgentPendingAction.set(name: name, args: args)
                return [
                    "confirm_required": "Ask-before-acting is on. Ready to run \(name) with \(summarize(args)). Tell the user what will happen and ask them to say 'confirm' or 'cancel'.",
                ]
            default:
                break
            }
        }

        let result = await executeUngated(name: name, args: args)
        if AgentControlMode.isMutating(name), result["error"] == nil {
            AgentMacros.record(tool: name, args: args)
        }
        return result
    }

    /// Runs a tool with no control-mode gate. Used for confirmed actions and macro replay.
    static func executeUngated(name: String, args: [String: Any]) async -> [String: Any] {
        if AgentPlugins.isPlugin(name), !Self.builtinPluginTools.contains(name) {
            var result = await AgentPlugins.run(name: name, args: args)
            let exit = (result["exit"] as? Int) ?? 0
            if result["error"] != nil || exit != 0 {
                // Self-repair: the model can rewrite the manifest under the same name.
                result["repair_hint"] = "This plugin failed. Read the output, fix the template, and call plugin_create with the same name to replace it, then run it again."
            }
            return result
        }
        if let handled = await executeComputerTool(name: name, args: args) { return handled }
        return await executeBuiltin(name: name, args: args)
    }

    /// The built-in plugin management tools share the `plugin_` prefix with user manifests.
    static let builtinPluginTools: Set<String> = ["plugin_list", "plugin_create", "plugin_delete"]

    /// Tools that ask for confirmation regardless of mode (they really send something).
    private static func alwaysConfirms(_ name: String) -> Bool { name == "messages_send" }

    private static func confirmPending() async -> [String: Any] {
        guard AgentControlMode.current != .observeOnly else {
            AgentPendingAction.clear()
            return ["error": "observe-only mode: nothing can be confirmed"]
        }
        guard let pending = AgentPendingAction.take() else {
            return ["error": "nothing pending to confirm — a confirmation must come from the user's next request, not from the same turn"]
        }
        if pending.name == "messages_send_confirmed" {
            let to = (pending.args["to"] as? String) ?? ""
            let text = (pending.args["text"] as? String) ?? ""
            return await MainActor.run { messagesSend(to: to, text: text) }
        }
        let result = await executeUngated(name: pending.name, args: pending.args)
        if result["error"] == nil { AgentMacros.record(tool: pending.name, args: pending.args) }
        return result
    }

    private static func summarize(_ args: [String: Any]) -> String {
        let parts = args.map { "\($0.key)=\(String(describing: $0.value).prefix(60))" }.sorted()
        return parts.isEmpty ? "no arguments" : parts.joined(separator: ", ")
    }

    // MARK: - Computer control + system tools

    /// Returns nil when `name` is not one of the tools defined here.
    static func executeComputerTool(name: String, args: [String: Any]) async -> [String: Any]? {
        @Sendable func s(_ key: String) -> String { (args[key] as? String) ?? "" }
        // Model-supplied numbers are untrusted: NaN, ±inf or absurd magnitudes must not trap.
        @Sendable func n(_ key: String) -> Double? {
            let raw: Double?
            if let d = args[key] as? Double { raw = d }
            else if let i = args[key] as? Int { raw = Double(i) }
            else if let v = args[key] as? NSNumber { raw = v.doubleValue }
            else if let str = args[key] as? String { raw = Double(str) }
            else { raw = nil }
            guard let raw, raw.isFinite, abs(raw) < 1_000_000_000 else { return nil }
            return raw
        }
        @Sendable func i(_ key: String, _ fallback: Int) -> Int { n(key).map { Int($0) } ?? fallback }
        @Sendable func b(_ key: String, _ fallback: Bool) -> Bool {
            if let v = args[key] as? Bool { return v }
            if let str = args[key] as? String { return ["true", "yes", "1"].contains(str.lowercased()) }
            return fallback
        }
        func needsAccessibility() -> [String: Any]? {
            guard !AgentInputSynth.isAccessibilityGranted else { return nil }
            AgentInputSynth.requestAccessibility()
            return ["error": "Accessibility permission is required for this. macOS just prompted the user — ask them to enable VoxOS under Privacy & Security → Accessibility, then try again."]
        }

        switch name {

        // MARK: See the screen
        case "read_screen", "see_screen":
            return await AgentScreen.readScreenText()

        case "find_text":
            guard let shot = await AgentScreen.capture() else { return ["error": "screen capture failed — Screen Recording permission may be missing"] }
            let matches = AgentScreen.filter(await AgentScreen.recognizeText(in: shot), query: s("query"))
            return [
                "frontmost": shot.frontmostApp, "count": matches.count,
                "matches": matches.prefix(40).map {
                    ["text": $0.text, "x": Int($0.frame.midX), "y": Int($0.frame.midY), "confidence": Double($0.confidence)]
                },
            ]

        case "list_ui_elements":
            if let e = needsAccessibility() { return e }
            let elements = AgentAXTree.enumerateFrontmost()
            let frontmost = await MainActor.run { NSWorkspace.shared.frontmostApplication?.localizedName ?? "?" }
            return [
                "frontmost": frontmost, "count": elements.count,
                "elements": elements.map {
                    ["role": $0.role, "title": String($0.title.prefix(60)), "x": Int($0.frame.midX), "y": Int($0.frame.midY)]
                },
            ]

        case "mark_screen":
            return await AgentMarks.markScreen()

        // MARK: Click things
        case "click_element":
            if let e = needsAccessibility() { return e }
            let query = s("name")
            guard !query.isEmpty else { return ["error": "name is required"] }
            // The tree can be briefly unreadable right after a previous press while the app
            // animates, so an empty match is retried before it is reported as missing.
            var match: AgentAXTree.Element?
            for attempt in 0..<4 {
                if attempt > 0 { try? await Task.sleep(nanoseconds: 180_000_000) }
                match = AgentAXTree.bestMatch(in: AgentAXTree.enumerateFrontmost(), name: query, role: args["role"] as? String)
                if match != nil { break }
            }
            guard let match else {
                return ["error": "no element matching \"\(query)\"", "hint": "call list_ui_elements to see what's available, or click_text to click visible text"]
            }
            let count = i("count", 1)
            let pressed = count == 1 && AgentAXTree.tryPress(match.element)
            if !pressed { AgentInputSynth.click(at: CGPoint(x: match.frame.midX, y: match.frame.midY), count: count) }
            try? await Task.sleep(nanoseconds: 250_000_000)
            return ["ok": true, "via": pressed ? "AXPress" : "click", "clicked": ["role": match.role, "title": match.title]]

        case "click_text":
            if let e = needsAccessibility() { return e }
            let query = s("query")
            guard !query.isEmpty else { return ["error": "query is required"] }
            guard let shot = await AgentScreen.capture() else { return ["error": "screen capture failed"] }
            let matches = AgentScreen.filter(await AgentScreen.recognizeText(in: shot), query: query)
            let index = i("match_index", 0)
            guard !matches.isEmpty, index >= 0, index < matches.count else {
                return ["error": "no text matching \"\(query)\" on screen", "ocr_count": matches.count]
            }
            let target = matches[index]
            AgentInputSynth.click(at: CGPoint(x: target.frame.midX, y: target.frame.midY))
            try? await Task.sleep(nanoseconds: 250_000_000)
            return ["ok": true, "matched_text": target.text]

        case "click_mark":
            if let e = needsAccessibility() { return e }
            let number = i("mark", -1)
            guard let mark = await AgentMarks.mark(numbered: number) else {
                return ["error": "no mark numbered \(number)", "hint": "call mark_screen first"]
            }
            AgentInputSynth.click(at: CGPoint(x: mark.frame.midX, y: mark.frame.midY))
            await AgentMarks.clear()
            try? await Task.sleep(nanoseconds: 250_000_000)
            return ["ok": true, "mark": number, "label": mark.label]

        // MARK: Raw input
        case "mouse_move":
            if let e = needsAccessibility() { return e }
            guard let x = n("x"), let y = n("y") else { return ["error": "x and y are required — get them from list_ui_elements or find_text"] }
            AgentInputSynth.move(to: CGPoint(x: x, y: y))
            return ["ok": true]

        case "mouse_click":
            if let e = needsAccessibility() { return e }
            guard let x = n("x"), let y = n("y") else { return ["error": "x and y are required — get them from list_ui_elements or find_text"] }
            let button: CGMouseButton = s("button").lowercased() == "right" ? .right : .left
            AgentInputSynth.click(at: CGPoint(x: x, y: y), button: button, count: min(3, max(1, i("count", 1))))
            try? await Task.sleep(nanoseconds: 200_000_000)
            return ["ok": true]

        case "mouse_drag":
            if let e = needsAccessibility() { return e }
            guard let fx = n("from_x"), let fy = n("from_y"), let tx = n("to_x"), let ty = n("to_y") else {
                return ["error": "from_x, from_y, to_x and to_y are all required"]
            }
            AgentInputSynth.drag(from: CGPoint(x: fx, y: fy), to: CGPoint(x: tx, y: ty), durationMs: min(5000, max(50, i("duration_ms", 350))))
            return ["ok": true]

        case "scroll":
            if let e = needsAccessibility() { return e }
            if let x = n("x"), let y = n("y") { AgentInputSynth.move(to: CGPoint(x: x, y: y)) }
            AgentInputSynth.scroll(deltaX: Int32(clamping: i("delta_x", 0)), deltaY: Int32(clamping: i("delta_y", 0)))
            return ["ok": true]

        case "press_key":
            if let e = needsAccessibility() { return e }
            let key = s("key")
            let modifiers = (args["modifiers"] as? [String]) ?? []
            guard AgentInputSynth.pressKey(key, modifiers: modifiers) else { return ["error": "unknown key \"\(key)\""] }
            return ["ok": true, "key": key, "modifiers": modifiers]

        case "hotkey":
            if let e = needsAccessibility() { return e }
            var keys = (args["keys"] as? [String]) ?? []
            if keys.isEmpty { keys = s("keys").split(whereSeparator: { "+ ".contains($0) }).map(String.init) }
            let modifiers = keys.filter { AgentInputSynth.modifierNames.contains($0.lowercased()) }
            guard let main = keys.last(where: { !AgentInputSynth.modifierNames.contains($0.lowercased()) }) else {
                return ["error": "no main key in \(keys)"]
            }
            guard AgentInputSynth.pressKey(main, modifiers: modifiers) else { return ["error": "unknown key \"\(main)\""] }
            return ["ok": true, "keys": keys]

        case "undo_last_action":
            if let e = needsAccessibility() { return e }
            AgentInputSynth.pressKey("z", modifiers: ["cmd"])
            return ["ok": true, "note": "sent ⌘Z to the frontmost app"]

        // MARK: Sequencing
        case "wait":
            let seconds = min(30, max(0, n("seconds") ?? 1))
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return ["ok": true, "waited_seconds": seconds]

        case "wait_for_text":
            let target = s("text").lowercased()
            guard !target.isEmpty else { return ["error": "text is required"] }
            let timeout = min(60, max(1, i("timeout_seconds", 15)))
            let deadline = Date().addingTimeInterval(TimeInterval(timeout))
            while Date() < deadline {
                if let shot = await AgentScreen.capture(),
                    await AgentScreen.recognizeText(in: shot, accurate: false).contains(where: { $0.text.lowercased().contains(target) })
                {
                    return ["found": true, "text": s("text")]
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
            return ["found": false, "text": s("text"), "timeout_seconds": timeout]

        case "batch_actions":
            let steps = (args["actions"] as? [[String: Any]]) ?? []
            guard !steps.isEmpty else { return ["error": "actions is required: a list of {\"tool\": ..., \"args\": {...}}"] }
            let stopOnError = b("stop_on_error", true)
            let dryRun = b("dry_run", false)
            var results: [[String: Any]] = []
            var failed = false
            for step in steps {
                let tool = (step["tool"] as? String) ?? (step["type"] as? String) ?? ""
                let stepArgs = (step["args"] as? [String: Any]) ?? step.filter { $0.key != "tool" && $0.key != "type" }
                guard tool != "batch_actions" else { continue }
                if dryRun {
                    results.append(["tool": tool, "would_run": summarize(stepArgs)])
                    continue
                }
                let result = await executeUngated(name: tool, args: stepArgs)
                results.append(["tool": tool, "result": result])
                if result["error"] != nil {
                    failed = true
                    if stopOnError { break }
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            return ["ok": !failed, "dry_run": dryRun, "steps_run": results.count, "results": results]

        // MARK: Apps & windows
        case "frontmost_app":
            return await MainActor.run { AgentWindows.frontmostApp() }
        case "list_apps":
            return await MainActor.run { ["apps": AgentWindows.listApps()] }
        case "activate_app":
            return await MainActor.run { AgentWindows.activateApp(query: s("name")) }
        case "list_windows":
            return ["windows": AgentWindows.listWindows()]
        case "set_window_bounds":
            return await MainActor.run {
                AgentWindows.setWindowBounds(appQuery: s("app"), x: n("x") ?? 0, y: n("y") ?? 0, width: n("width") ?? 800, height: n("height") ?? 600)
            }

        // MARK: Shell, files, clipboard
        case "run_shell":
            return await AgentShell.run(s("command"))
        case "run_applescript":
            let script = s("script")
            guard !script.isEmpty else { return ["error": "script is required"] }
            if let risk = AgentShell.riskReason(script), !UserDefaults.standard.bool(forKey: AgentShell.allowRiskyKey) {
                return ["blocked": true, "risk": risk, "error": "blocked: this script looks risky (\(risk)) and was NOT run. The user can enable “Allow risky shell commands” in Settings → Agent."]
            }
            return await MainActor.run { AgentAppleScript.run(script) }
        case "read_file":
            return AgentFiles.readFile(path: s("path"))
        case "read_pdf":
            return AgentFiles.readPDF(path: s("path"))
        case "move_file":
            return AgentFiles.move(from: s("from"), to: s("to"))
        case "read_clipboard":
            return await MainActor.run {
                let pasteboard = NSPasteboard.general
                if let items = pasteboard.readObjects(forClasses: [NSString.self], options: nil) as? [String],
                    let text = items.first(where: { !$0.isEmpty })
                {
                    return ["text": text.count > 4000 ? String(text.prefix(4000)) + "…" : text, "length": text.count]
                }
                return ["text": "", "note": "no readable text on the clipboard", "available_types": (pasteboard.types ?? []).map(\.rawValue)]
            }

        // MARK: Browser
        case "browser_snapshot":
            return await MainActor.run { AgentBrowser.snapshot() }
        case "browser_click_text":
            return await MainActor.run { AgentBrowser.clickText(s("text")) }
        case "browser_run_js":
            return await MainActor.run { AgentBrowser.runJS(s("js")) }
        case "list_browser_tabs":
            return await MainActor.run { AgentBrowser.listTabs() }
        case "switch_browser_tab":
            return await MainActor.run { AgentBrowser.switchTab(index: i("index", 0)) }
        case "fetch_url":
            return await AgentWeb.fetch(s("url"))
        case "web_results":
            return await AgentWeb.search(s("query"))

        // MARK: Macros
        case "macro_record_start":
            return AgentMacros.startRecording(name: s("name"))
        case "macro_record_stop":
            return AgentMacros.stopRecording()
        case "macro_list":
            return ["macros": AgentMacros.list().map { ["name": $0.name, "steps": $0.steps.count] }]
        case "macro_delete":
            return AgentMacros.delete(s("name")) ? ["ok": true, "deleted": s("name")] : ["error": "no macro named \(s("name"))"]
        case "macro_run":
            guard let macro = AgentMacros.load(s("name")) else {
                return ["error": "no macro named \(s("name"))", "available": AgentMacros.list().map(\.name)]
            }
            var failures: [[String: Any]] = []
            for (index, step) in macro.steps.enumerated() {
                let result = await executeUngated(name: step.tool, args: step.args)
                if result["error"] != nil { failures.append(["step": index + 1, "tool": step.tool, "error": result["error"] ?? ""]) }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            return ["ok": failures.isEmpty, "macro": macro.name, "steps_run": macro.steps.count, "failed_steps": failures]

        // MARK: Plugins
        case "plugin_list":
            return ["plugins": AgentPlugins.load().map { ["tool": $0.name, "description": $0.description, "args": Array($0.parameters.keys)] }]
        case "plugin_create":
            let parameters = (args["parameters"] as? [String: String]) ?? [:]
            return AgentPlugins.create(name: s("name"), description: s("description"), runType: s("run_type"), template: s("template"), parameters: parameters)
        case "plugin_delete":
            return AgentPlugins.delete(name: s("name"))

        // MARK: Ambient + modes
        case "watch_for":
            return await MainActor.run { AgentWatcher.watch(forText: s("text"), timeoutSeconds: i("timeout_seconds", 600)) }
        case "watch_list":
            return await MainActor.run { AgentWatcher.list() }
        case "watch_cancel":
            return await MainActor.run { AgentWatcher.cancel(id: args["watch_id"] as? String) }

        case "set_control_mode":
            let raw = s("mode").lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
            let mode: AgentControlMode?
            switch raw {
            case "takeover", "act_freely", "free", "act": mode = .takeover
            case "ask_before_action", "ask", "confirm": mode = .askBeforeAction
            case "observe_only", "observe", "read_only", "watch": mode = .observeOnly
            default: mode = nil
            }
            guard let mode else { return ["error": "mode must be one of takeover, ask_before_action, observe_only"] }
            AgentControlMode.current = mode
            return ["ok": true, "mode": mode.rawValue, "note": mode.summary]

        case "get_control_mode":
            return ["mode": AgentControlMode.current.rawValue]

        // MARK: System audio (what the Mac is playing)
        case "system_audio_start":
            return await SystemAudioCaptureController.shared.agentStart()
        case "system_audio_stop":
            return await SystemAudioCaptureController.shared.agentStop()
        case "system_audio_recall":
            return await SystemAudioCaptureController.shared.agentRecall(seconds: n("seconds") ?? 30)
        case "watch_for_audio":
            return await MainActor.run { AgentWatcher.watchAudio(forText: s("text"), timeoutSeconds: i("timeout_seconds", 600)) }

        // MARK: Pause & resume
        case "wait_for_user":
            let question = s("question")
            guard !question.isEmpty else { return ["error": "question is required"] }
            AgentPausedTask.set(question: question, context: s("context"))
            return ["ok": true, "note": "Task paused. Finish this reply with exactly that question in plain text; the user's next request will be treated as the answer and you will be reminded of the context."]

        // MARK: Learning language
        case "set_learning_language":
            let language = s("language").trimmingCharacters(in: .whitespacesAndNewlines)
            if language.isEmpty || ["off", "none", "stop"].contains(language.lowercased()) {
                UserDefaults.standard.removeObject(forKey: "agentLearningLanguage")
                return ["ok": true, "learning_language": "off"]
            }
            UserDefaults.standard.set(language, forKey: "agentLearningLanguage")
            return ["ok": true, "learning_language": language, "note": "From now on explain new words and phrases in \(language) context; call mark_vocabulary_known when the user says they know a word."]
        case "mark_vocabulary_known":
            let word = s("word").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty else { return ["error": "word is required"] }
            return await MainActor.run {
                guard let context = AgentEnvironment.engine?.modelContext else { return ["error": "vocabulary store unavailable"] }
                let existing = (try? context.fetch(FetchDescriptor<VocabularyWord>())) ?? []
                if let message = DictionaryService.addVocabularyWords(word, existing: existing, context: context) {
                    return ["ok": true, "word": word, "note": message]
                }
                return ["ok": true, "word": word, "note": "added to the custom vocabulary so it is spelled correctly from now on"]
            }

        // MARK: Diagnostics + secrets
        case "permissions_diagnostics":
            return [
                "microphone": authStatus(AVCaptureDevice.authorizationStatus(for: .audio).rawValue),
                "speech_recognition": speechAuthStatus(SFSpeechRecognizer.authorizationStatus()),
                "screen_recording": AgentScreen.hasPermission ? "authorized" : "not_authorized",
                "accessibility": AgentInputSynth.isAccessibilityGranted ? "authorized" : "not_authorized",
                "hint": "Screen Recording powers read_screen/find_text/mark_screen; Accessibility powers every click and keystroke.",
            ]

        case "system_status":
            return await systemStatus()

        case "secret_save":
            let key = s("name"), value = s("value")
            guard !key.isEmpty, !value.isEmpty else { return ["error": "name and value are required"] }
            KeychainService.shared.save(value, forKey: "AgentSecret.\(key.lowercased())")
            return ["ok": true, "saved": key, "note": "stored in the Keychain; read back with secret_exists or by name in plugins as {{secret:name}}"]

        case "secret_exists":
            let key = s("name")
            let exists = (KeychainService.shared.getString(forKey: "AgentSecret.\(key.lowercased())") ?? "").isEmpty == false
            return ["name": key, "exists": exists]

        default:
            return nil
        }
    }

    /// SFSpeechRecognizer orders its cases differently from AVFoundation (denied=1, restricted=2).
    private static func speechAuthStatus(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "not_determined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }

    private static func authStatus(_ raw: Int) -> String {
        switch raw {
        case 0: return "not_determined"
        case 1: return "restricted"
        case 2: return "denied"
        case 3: return "authorized"
        default: return "unknown"
        }
    }

    private static func systemStatus() async -> [String: Any] {
        let processInfo = ProcessInfo.processInfo
        var status: [String: Any] = [
            "uptime_hours": Int(processInfo.systemUptime / 3600),
            "macos": processInfo.operatingSystemVersionString,
            "memory_gb": Int(processInfo.physicalMemory / 1_073_741_824),
            "thermal_state": ["nominal", "fair", "serious", "critical"][min(3, processInfo.thermalState.rawValue)],
            "low_power_mode": processInfo.isLowPowerModeEnabled,
        ]
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()),
            let free = attrs[.systemFreeSize] as? Int64
        {
            status["free_disk_gb"] = Int(free / 1_073_741_824)
        }
        let battery = await AgentShell.run("pmset -g batt | grep -oE '[0-9]+%' | head -1")
        if let output = (battery["output"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
            status["battery"] = output
        }
        status["frontmost"] = await MainActor.run { NSWorkspace.shared.frontmostApplication?.localizedName ?? "" }
        return status
    }
}
