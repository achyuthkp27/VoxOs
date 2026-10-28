import Foundation

/// One hook call from Claude Code, decoded from the JSON body its HTTP hook POSTs to the bridge.
///
/// Only the fields the notch shows or correlates on are kept. Everything else in the payload
/// (transcript path, effort, scratchpad) is ignored, and an event VoxOS does not know decodes to
/// nil so the bridge can answer it with an empty 200 and never get in Claude Code's way.
struct ClaudeCodeHookEvent: Equatable {
    enum Kind: String, CaseIterable {
        case sessionStart = "SessionStart"
        case sessionEnd = "SessionEnd"
        case userPromptSubmit = "UserPromptSubmit"
        case preToolUse = "PreToolUse"
        case permissionRequest = "PermissionRequest"
        case postToolUse = "PostToolUse"
        case postToolUseFailure = "PostToolUseFailure"
        case notification = "Notification"
        case stop = "Stop"
        case stopFailure = "StopFailure"
    }

    let kind: Kind
    let sessionID: String
    let cwd: String?
    let toolName: String?
    /// Present on PreToolUse and PostToolUse, absent on PermissionRequest (measured on 2.1.312).
    let toolUseID: String?
    /// The tool input as JSON with sorted keys, so a PermissionRequest can be matched to the
    /// PreToolUse that preceded it by comparing strings.
    let toolInputKey: String?
    let summary: ClaudeCodeToolSummary?
    let notificationType: String?
    /// "default", "acceptEdits", "plan", "auto"…: whether "switch to auto mode" means anything.
    let permissionMode: String?
    /// The "always allow" updates the CLI offers for a PermissionRequest, as JSON; a hook grants
    /// them by echoing them back as `updatedPermissions`.
    let permissionSuggestionsKey: String?
    /// The questions of an AskUserQuestion call.
    let questions: [ClaudeCodeQuestion]?
    /// ExitPlanMode: the plan as markdown, empty when the call did not carry it.
    let plan: String?
    /// The session's transcript, which says what hooks do not: its title, its branch, an Esc.
    let transcriptPath: String?
    /// The CLI's process, when the hook reported it; set by the bridge, not part of the JSON.
    var cliPID: Int32?

    /// The folder the session runs in, which is what the notch names it by.
    var project: String {
        guard let cwd, !cwd.isEmpty else { return "Claude Code" }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    static func decode(_ data: Data) -> ClaudeCodeHookEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return decode(object)
    }

    static func decode(_ object: [String: Any]) -> ClaudeCodeHookEvent? {
        guard let name = object["hook_event_name"] as? String, let kind = Kind(rawValue: name),
            let sessionID = object["session_id"] as? String, !sessionID.isEmpty
        else { return nil }
        let cwd = object["cwd"] as? String
        let toolName = object["tool_name"] as? String
        let toolInput = object["tool_input"] as? [String: Any]
        let suggestions = (object["permission_suggestions"] as? [Any]).flatMap { $0.isEmpty ? nil : $0 }
        return ClaudeCodeHookEvent(
            kind: kind,
            sessionID: sessionID,
            cwd: cwd,
            toolName: toolName,
            toolUseID: object["tool_use_id"] as? String,
            toolInputKey: toolInput.flatMap { canonicalJSON($0) },
            summary: toolName.map { ClaudeCodeToolSummary(toolName: $0, input: toolInput ?? [:], cwd: cwd) },
            notificationType: object["notification_type"] as? String,
            permissionMode: object["permission_mode"] as? String,
            permissionSuggestionsKey: suggestions.flatMap { canonicalJSON($0) },
            questions: toolName == "AskUserQuestion" ? ClaudeCodeQuestion.decode(toolInput?["questions"]) : nil,
            plan: toolName == "ExitPlanMode" ? (toolInput?["plan"] as? String ?? "") : nil,
            transcriptPath: (object["transcript_path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    /// The tool input back as an object, for a decision that has to echo it (AskUserQuestion).
    var toolInput: [String: Any] {
        guard let toolInputKey, let data = toolInputKey.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    var permissionSuggestions: [Any] {
        guard let permissionSuggestionsKey, let data = permissionSuggestionsKey.data(using: .utf8) else { return [] }
        return (try? JSONSerialization.jsonObject(with: data) as? [Any]) ?? []
    }

    static func canonicalJSON(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// What a tool call is about to do, in the words the approval card shows: a short title and the
/// one detail that decides whether to allow it (the command, the file, the URL).
struct ClaudeCodeToolSummary: Equatable {
    let title: String
    let detail: String

    /// The card shows at most a few lines; a Write carrying a whole file is cut well before that.
    static let maxDetailLength = 600

    init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }

    init(toolName: String, input: [String: Any], cwd: String?) {
        func string(_ key: String) -> String { (input[key] as? String) ?? "" }
        func path(_ key: String) -> String { Self.displayPath(string(key), cwd: cwd) }

        let title: String
        let detail: String
        switch toolName {
        case "Bash":
            title = String(localized: "Run command")
            detail = string("command")
        case "Edit", "MultiEdit":
            title = String(localized: "Edit file")
            detail = path("file_path")
        case "Write":
            title = String(localized: "Write file")
            detail = path("file_path")
        case "Read":
            title = String(localized: "Read file")
            detail = path("file_path")
        case "NotebookEdit":
            title = String(localized: "Edit notebook")
            detail = path("notebook_path")
        case "WebFetch":
            title = String(localized: "Fetch web page")
            detail = string("url")
        case "WebSearch":
            title = String(localized: "Search the web")
            detail = string("query")
        case "Glob", "Grep":
            title = String(localized: "Search files")
            detail = string("pattern")
        case "Task", "Agent":
            title = String(localized: "Start an agent")
            detail = string("description")
        case "ExitPlanMode":
            title = String(localized: "Approve the plan")
            detail = string("plan").split(separator: "\n").first.map(String.init) ?? ""
        default:
            if toolName.hasPrefix("mcp__") {
                // mcp__<server>__<tool>. Server names can hold single underscores
                // (claude_ai_Gmail), so only the double underscore separates the two.
                let rest = toolName.dropFirst("mcp__".count)
                if let separator = rest.range(of: "__") {
                    title = "\(rest[..<separator.lowerBound]) · \(rest[separator.upperBound...])"
                } else {
                    title = String(rest)
                }
            } else {
                title = String(localized: "Use \(toolName)")
            }
            detail = Self.compactJSON(input)
        }
        self.init(title: title, detail: Self.clipped(detail.isEmpty ? Self.compactJSON(input) : detail))
    }

    /// Home becomes ~, and a file inside the session's folder is shown relative to it.
    static func displayPath(_ path: String, cwd: String?) -> String {
        guard !path.isEmpty else { return path }
        if let cwd, !cwd.isEmpty, path.hasPrefix(cwd + "/") {
            return String(path.dropFirst(cwd.count + 1))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~/" + path.dropFirst(home.count + 1) }
        return path
    }

    static func compactJSON(_ input: [String: Any]) -> String {
        guard !input.isEmpty else { return "" }
        return ClaudeCodeHookEvent.canonicalJSON(input) ?? ""
    }

    static func clipped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxDetailLength else { return trimmed }
        return String(trimmed.prefix(maxDetailLength)) + "…"
    }
}

/// One multiple-choice question from AskUserQuestion: the question, a short header, two to four
/// options, and whether several may be picked.
struct ClaudeCodeQuestion: Equatable {
    struct Option: Equatable {
        let label: String
        let description: String

        /// Claude often repeats the label as the description ("Apple", "Apple"); a second line
        /// that says nothing new is left out.
        var addsToLabel: Bool {
            let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && text.caseInsensitiveCompare(label) != .orderedSame
        }
    }

    let question: String
    let header: String
    let options: [Option]
    let multiSelect: Bool

    static func decode(_ value: Any?) -> [ClaudeCodeQuestion]? {
        guard let items = value as? [[String: Any]] else { return nil }
        let questions = items.compactMap { item -> ClaudeCodeQuestion? in
            guard let question = item["question"] as? String, !question.isEmpty else { return nil }
            let options = (item["options"] as? [[String: Any]] ?? []).compactMap { option -> Option? in
                guard let label = option["label"] as? String, !label.isEmpty else { return nil }
                return Option(label: label, description: option["description"] as? String ?? "")
            }
            guard !options.isEmpty else { return nil }
            return ClaudeCodeQuestion(
                question: question, header: item["header"] as? String ?? "", options: options,
                multiSelect: item["multiSelect"] as? Bool ?? false)
        }
        return questions.isEmpty ? nil : questions
    }

    /// What the CLI expects in `answers`: the chosen labels, in the options' order, joined with
    /// commas when several are picked.
    func answer(choosing labels: Set<String>) -> String {
        options.map(\.label).filter(labels.contains).joined(separator: ", ")
    }
}

/// The "always allow" a PermissionRequest offers, in the words the card's tooltip uses.
enum ClaudeCodePermissionSuggestion {
    static func describe(_ suggestions: [Any]) -> String? {
        let parts = suggestions.compactMap { $0 as? [String: Any] }.compactMap { entry -> String? in
            switch entry["type"] as? String {
            case "addRules":
                let rules = (entry["rules"] as? [[String: Any]] ?? []).map {
                    ($0["ruleContent"] as? String) ?? ($0["toolName"] as? String) ?? ""
                }.filter { !$0.isEmpty }
                return rules.isEmpty ? nil : String(localized: "Don't ask again for \(rules.joined(separator: ", "))")
            case "addDirectories":
                let directories = (entry["directories"] as? [String] ?? []).map {
                    ClaudeCodeToolSummary.displayPath($0, cwd: nil)
                }
                return directories.isEmpty
                    ? nil : String(localized: "Allow access to \(directories.joined(separator: ", "))")
            case "setMode":
                return (entry["mode"] as? String) == "acceptEdits"
                    ? String(localized: "Accept edits for the rest of the session") : nil
            default:
                return nil
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}
