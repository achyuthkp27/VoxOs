import AppKit
import Foundation

/// Runs AppleScript on the main thread (NSAppleScript is not thread-safe).
enum AgentAppleScript {
    @MainActor
    static func run(_ source: String) -> [String: Any] {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            return ["error": "could not parse AppleScript"]
        }
        let result = script.executeAndReturnError(&error)
        if let error {
            return ["error": (error["NSAppleScriptErrorMessage"] as? String) ?? "AppleScript error"]
        }
        return ["result": result.stringValue ?? "ok"]
    }
}

/// Voice-agent tools. Ported/adapted from cursor-voice (MIT) NativeConnectors + FileOps.
/// All connectors are draft-safe: mail composes a draft, nothing auto-sends.
enum AgentTools {
    static let browserBundleIdentifiers: [String: String] = [
        "chrome": "com.google.Chrome",
        "google chrome": "com.google.Chrome",
        "safari": "com.apple.Safari",
        "firefox": "org.mozilla.firefox",
        "arc": "company.thebrowser.Browser",
        "brave": "com.brave.Browser",
        "edge": "com.microsoft.edgemac",
    ]

    /// App-integration tools. Called through `execute` (see AgentTools+Computer.swift),
    /// which applies the control-mode gate and routes computer-control tools first.
    static func executeBuiltin(name: String, args: [String: Any]) async -> [String: Any] {
        @Sendable func s(_ key: String) -> String { (args[key] as? String) ?? "" }
        @Sendable func i(_ key: String, _ def: Int) -> Int {
            if let v = args[key] as? Int { return v }
            if let v = args[key] as? Double { return Int(v) }
            return Int(s(key)) ?? def
        }

        switch name {
        case "get_datetime":
            let now = Date()
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            let dayFormatter = DateFormatter()
            dayFormatter.dateFormat = "EEEE"
            let displayFormatter = DateFormatter()
            displayFormatter.dateFormat = "h:mm a"
            return [
                "now": formatter.string(from: now),
                "weekday": dayFormatter.string(from: now),
                "display_time": displayFormatter.string(from: now),
                "timezone": TimeZone.current.identifier,
            ]

        case "calendar_add_event":
            return await MainActor.run {
                calendarAddEvent(
                    title: s("title"), start: s("start"),
                    durationMinutes: i("duration_minutes", 60),
                    notes: s("notes"), calendar: s("calendar"))
            }

        case "calendar_today":
            return await MainActor.run { calendarToday() }

        case "reminders_add":
            return await MainActor.run {
                remindersAdd(text: s("text"), due: s("due"), list: s("list"))
            }

        case "notes_create":
            return await MainActor.run { notesCreate(title: s("title"), body: s("body")) }

        case "mail_compose":
            return await MainActor.run {
                mailCompose(to: s("to"), subject: s("subject"), body: s("body"))
            }

        case "find_files":
            return findFiles(query: s("query"), dir: s("dir"))

        case "open_app":
            let appName = s("name")
            guard !appName.isEmpty else { return ["error": "name is required"] }
            return await MainActor.run { AgentWindows.openApp(name: appName) }

        case "open_url":
            guard let url = URL(string: s("url")),
                let scheme = url.scheme?.lowercased(),
                ["http", "https", "mailto", "tel", "facetime", "maps", "x-apple.systempreferences"].contains(scheme)
            else {
                return ["error": "invalid url: supported schemes are http, https, mailto, tel, facetime, maps, x-apple.systempreferences"]
            }
            let browserName = s("browser")
            return await MainActor.run {
                guard !browserName.isEmpty,
                    let bundleID = Self.browserBundleIdentifiers[browserName.lowercased()],
                    let browserURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                else {
                    if browserName.isEmpty {
                        NSWorkspace.shared.open(url)
                        return ["result": "opened \(url.absoluteString)"]
                    }
                    NSWorkspace.shared.open(url)
                    return ["result": "opened \(url.absoluteString) (couldn't find \(browserName) installed, used default browser instead)"]
                }

                NSWorkspace.shared.open(
                    [url], withApplicationAt: browserURL, configuration: NSWorkspace.OpenConfiguration())
                return ["result": "opened \(url.absoluteString) in \(browserName)"]
            }

        case "type_text":
            let text = s("text")
            guard !text.isEmpty else { return ["error": "text is required"] }
            await MainActor.run { _ = CursorPaster.startPasteAtCursor(text) }
            return ["result": "typed text at cursor"]

        case "clipboard_write":
            let text = s("text")
            return await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                return ["result": "copied to clipboard"]
            }

        case "calendar_upcoming":
            return await MainActor.run { calendarUpcoming(days: i("days", 7)) }

        case "reminders_list":
            return await MainActor.run { remindersList(list: s("list")) }

        case "web_search":
            let query = s("query")
            guard !query.isEmpty else { return ["error": "query is required"] }
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            guard let url = URL(string: "https://www.google.com/search?q=\(encoded)") else {
                return ["error": "could not build search URL"]
            }
            return await MainActor.run {
                NSWorkspace.shared.open(url)
                return ["result": "opened web search for: \(query)"]
            }

        case "whatsapp_send":
            let text = s("text")
            guard !text.isEmpty else { return ["error": "text is required"] }
            let phone = s("phone").filter { $0.isNumber }
            let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
            let urlString =
                phone.isEmpty
                ? "whatsapp://send?text=\(encoded)"
                : "whatsapp://send?phone=\(phone)&text=\(encoded)"
            guard let url = URL(string: urlString) else { return ["error": "could not build WhatsApp URL"] }
            return await MainActor.run {
                if NSWorkspace.shared.open(url) {
                    return ["result": "opened WhatsApp with the message prefilled — press Send to send it"]
                }
                let webURL = URL(string: "https://web.whatsapp.com/send?phone=\(phone)&text=\(encoded)")!
                NSWorkspace.shared.open(webURL)
                return ["result": "WhatsApp app not found; opened WhatsApp Web with the message prefilled"]
            }

        case "gmail_compose":
            var params: [String] = ["view=cm", "fs=1"]
            func q(_ v: String) -> String {
                v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
            }
            if !s("to").isEmpty { params.append("to=\(q(s("to")))") }
            if !s("subject").isEmpty { params.append("su=\(q(s("subject")))") }
            if !s("body").isEmpty { params.append("body=\(q(s("body")))") }
            guard let url = URL(string: "https://mail.google.com/mail/?" + params.joined(separator: "&")) else {
                return ["error": "could not build Gmail URL"]
            }
            return await MainActor.run {
                NSWorkspace.shared.open(url)
                return ["result": "opened a Gmail draft in the browser — review and press Send"]
            }

        case "gmail_search":
            let query = s("query")
            guard !query.isEmpty else { return ["error": "query is required"] }
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            guard let url = URL(string: "https://mail.google.com/mail/u/0/#search/\(encoded)") else {
                return ["error": "could not build Gmail search URL"]
            }
            return await MainActor.run {
                NSWorkspace.shared.open(url)
                return ["result": "opened Gmail search for: \(query)"]
            }

        case "linear_create_issue":
            return await linearCreateIssue(
                title: s("title"), description: s("description"), team: s("team"))

        case "linear_save_token":
            let token = s("token")
            guard !token.isEmpty else { return ["error": "token is required"] }
            KeychainService.shared.save(token, forKey: "AgentLinearAPIToken")
            return ["result": "Linear API token saved"]

        case "system_volume":
            let level = max(0, min(100, i("level", 50)))
            return await MainActor.run {
                AgentAppleScript.run("set volume output volume \(level)")
            }

        case "lock_screen":
            return await MainActor.run {
                let task = Process()
                task.launchPath = "/usr/bin/pmset"
                task.arguments = ["displaysleepnow"]
                try? task.run()
                return ["result": "locking screen"]
            }

        case "take_screenshot":
            return await MainActor.run { takeScreenshot() }

        case "slack_send":
            let to = s("to"), text = s("text")
            guard !to.isEmpty, !text.isEmpty else { return ["error": "to and text are required"] }
            guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.tinyspeck.slackmacgap") != nil
            else {
                return ["error": "Slack app is not installed"]
            }
            return await MainActor.run { slackSend(to: to, text: text) }

        case "contacts_find":
            return await MainActor.run { contactsFind(name: s("name")) }

        case "messages_send":
            let to = s("to"), text = s("text")
            guard !to.isEmpty, !text.isEmpty else { return ["error": "to and text are required"] }
            AgentPendingAction.set(name: "messages_send_confirmed", args: ["to": to, "text": text])
            return [
                "confirm_required":
                    "Ready to iMessage \(to): \"\(text)\". Ask the user to say 'confirm' to send or 'cancel'."
            ]

        case "remember":
            return AgentMemory.remember(key: s("key"), value: s("value"))

        case "recall":
            return AgentMemory.recall(key: s("key"))

        case "location_now":
            return await AgentLocation.current()

        case "media_key":
            return await MainActor.run { mediaKey(action: s("action")) }

        default:
            return ["error": "unknown tool: \(name)", "hint": "reply with a plain-text answer if no tool fits"]
        }
    }

    // MARK: - AppleScript date helper (locale-safe field-by-field dates)

    private static func dateSetters(_ varName: String, from string: String) -> String? {
        let parts = string.split(whereSeparator: { " -:T".contains($0) }).map(String.init)
        guard parts.count >= 5,
            let y = Int(parts[0]), let mo = Int(parts[1]), let d = Int(parts[2]),
            let h = Int(parts[3]), let mi = Int(parts[4])
        else { return nil }
        return """
            set \(varName) to current date
            set year of \(varName) to \(y)
            set month of \(varName) to \(mo)
            set day of \(varName) to \(d)
            set hours of \(varName) to \(h)
            set minutes of \(varName) to \(mi)
            set seconds of \(varName) to 0
            """
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Calendar

    @MainActor
    private static func calendarAddEvent(
        title: String, start: String, durationMinutes: Int, notes: String, calendar: String
    ) -> [String: Any] {
        guard let startSetter = dateSetters("startDate", from: start) else {
            return ["error": "start must be 'YYYY-MM-DD HH:MM' (24-hour)"]
        }
        let calClause =
            calendar.isEmpty ? "first calendar whose writable is true" : "calendar \"\(esc(calendar))\""
        let script = """
            tell application "Calendar"
              \(startSetter)
              set endDate to startDate + (\(max(1, durationMinutes)) * minutes)
              tell (\(calClause))
                make new event with properties {summary:"\(esc(title))", start date:startDate, end date:endDate, description:"\(esc(notes))"}
              end tell
              return "ok"
            end tell
            """
        return AgentAppleScript.run(script)
    }

    @MainActor
    private static func calendarToday() -> [String: Any] {
        let script = """
            set output to ""
            set startOfDay to current date
            set hours of startOfDay to 0
            set minutes of startOfDay to 0
            set seconds of startOfDay to 0
            set endOfDay to startOfDay + (1 * days)
            tell application "Calendar"
              repeat with c in calendars
                repeat with e in (every event of c whose start date ≥ startOfDay and start date < endOfDay)
                  set output to output & (summary of e) & " — " & (time string of (start date of e)) & linefeed
                end repeat
              end repeat
            end tell
            if output is "" then return "No events today."
            return output
            """
        return AgentAppleScript.run(script)
    }

    // MARK: - Reminders

    @MainActor
    private static func remindersAdd(text: String, due: String, list: String) -> [String: Any] {
        guard !text.isEmpty else { return ["error": "text is required"] }
        let listClause = list.isEmpty ? "default list" : "list \"\(esc(list))\""
        var props = "name:\"\(esc(text))\""
        var dueSetter = ""
        if !due.isEmpty, let setter = dateSetters("dueDate", from: due) {
            dueSetter = setter
            props += ", due date:dueDate"
        }
        let script = """
            tell application "Reminders"
              \(dueSetter)
              tell \(listClause)
                make new reminder with properties {\(props)}
              end tell
              return "ok"
            end tell
            """
        return AgentAppleScript.run(script)
    }

    // MARK: - Notes

    @MainActor
    private static func notesCreate(title: String, body: String) -> [String: Any] {
        let html =
            "<div><b>\(esc(title))</b></div><div>\(esc(body).replacingOccurrences(of: "\n", with: "</div><div>"))</div>"
        let script = """
            tell application "Notes"
              try
                make new note at folder "Notes" of account "iCloud" with properties {body:"\(html)"}
              on error
                make new note at folder "Notes" of default account with properties {body:"\(html)"}
              end try
              return "ok"
            end tell
            """
        return AgentAppleScript.run(script)
    }

    // MARK: - Mail (draft only — never auto-sends)

    @MainActor
    private static func mailCompose(to: String, subject: String, body: String) -> [String: Any] {
        let script = """
            tell application "Mail"
              set msg to make new outgoing message with properties {subject:"\(esc(subject))", content:"\(esc(body))", visible:true}
              tell msg
                make new to recipient at end of to recipients with properties {address:"\(esc(to))"}
              end tell
              activate
              return "draft created"
            end tell
            """
        return AgentAppleScript.run(script)
    }

    // MARK: - Files

    private static func findFiles(query: String, dir: String) -> [String: Any] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.standardizedFileURL.path
        let requestedPath = ((dir.isEmpty ? "~" : dir) as NSString).expandingTildeInPath
        let base = URL(fileURLWithPath: requestedPath).standardizedFileURL.path
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return ["error": "empty query"] }
        // Sandbox to the user's home folder so a manipulated query can't be used to browse
        // arbitrary system or other-user directories (e.g. "/etc", "/Users/someoneElse").
        guard base == home || base.hasPrefix(home + "/") else {
            return ["error": "directory must be within your home folder"]
        }
        guard fm.fileExists(atPath: base) else { return ["error": "directory not found: \(base)"] }

        var matches: [String] = []
        var scanned = 0
        if let en = fm.enumerator(
            at: URL(fileURLWithPath: base),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        {
            for case let url as URL in en {
                scanned += 1
                if scanned > 30_000 { break }
                if url.lastPathComponent.lowercased().contains(q) {
                    matches.append(url.path)
                    if matches.count >= 25 { break }
                }
            }
        }
        return ["count": matches.count, "matches": matches]
    }

    // MARK: - Calendar / Reminders read tools

    @MainActor
    private static func calendarUpcoming(days: Int) -> [String: Any] {
        let span = max(1, min(days, 31))
        let script = """
            set output to ""
            set startOfDay to current date
            set hours of startOfDay to 0
            set minutes of startOfDay to 0
            set seconds of startOfDay to 0
            set endWindow to startOfDay + (\(span) * days)
            tell application "Calendar"
              repeat with c in calendars
                repeat with e in (every event of c whose start date ≥ startOfDay and start date < endWindow)
                  set output to output & (short date string of (start date of e)) & " " & (time string of (start date of e)) & " — " & (summary of e) & linefeed
                end repeat
              end repeat
            end tell
            if output is "" then return "No events in the next \(span) days."
            return output
            """
        return AgentAppleScript.run(script)
    }

    @MainActor
    private static func remindersList(list: String) -> [String: Any] {
        let listClause = list.isEmpty ? "default list" : "list \"\(esc(list))\""
        let script = """
            set output to ""
            tell application "Reminders"
              repeat with r in (reminders of \(listClause) whose completed is false)
                set output to output & (name of r) & linefeed
              end repeat
            end tell
            if output is "" then return "No open reminders."
            return output
            """
        return AgentAppleScript.run(script)
    }
}

/// Holds an action that must be confirmed by voice before it executes.
enum AgentPendingAction {
    private static var pending: (name: String, args: [String: Any], run: UUID, createdAt: Date)?
    private static var currentRun = UUID()
    private static let lock = NSLock()
    /// A pending action older than this is discarded rather than confirmed.
    static let expiry: TimeInterval = 5 * 60

    /// Called at the start of every agent run so a confirmation cannot come from the same turn.
    static func beginRun() {
        lock.lock(); defer { lock.unlock() }
        currentRun = UUID()
    }

    static func set(name: String, args: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        pending = (name, args, currentRun, Date())
    }

    /// Consumes the pending action only when it is eligible: created in an earlier run and
    /// not yet expired. A same-run attempt leaves it in place for the user's real answer.
    static func take() -> (name: String, args: [String: Any])? {
        lock.lock(); defer { lock.unlock() }
        guard let value = pending else { return nil }
        if Date().timeIntervalSince(value.createdAt) >= expiry {
            pending = nil
            return nil
        }
        guard value.run != currentRun else { return nil }
        pending = nil
        return (value.name, value.args)
    }

    static func clear() {
        lock.lock(); defer { lock.unlock() }
        pending = nil
    }
}

extension AgentTools {

    // MARK: - Linear (REST API; requires a personal API token saved via linear_save_token)

    static func linearCreateIssue(title: String, description: String, team: String) async -> [String: Any] {
        guard !title.isEmpty else { return ["error": "title is required"] }
        guard let token = KeychainService.shared.getString(forKey: "AgentLinearAPIToken"), !token.isEmpty
        else {
            return [
                "error":
                    "No Linear API token saved. Ask the user for a Linear personal API key (linear.app/settings/api) and call linear_save_token with it first."
            ]
        }

        var teamId = team
        if teamId.isEmpty {
            let teamsQuery = "{ teams(first: 1) { nodes { id name } } }"
            if let result = try? await linearGraphQL(query: teamsQuery, token: token),
                let data = result["data"] as? [String: Any],
                let teams = data["teams"] as? [String: Any],
                let nodes = teams["nodes"] as? [[String: Any]],
                let first = nodes.first,
                let id = first["id"] as? String
            {
                teamId = id
            } else {
                return ["error": "Could not resolve a Linear team. Specify a team name/ID."]
            }
        }

        let mutation = """
            mutation {
              issueCreate(input: { title: "\(escGraphQL(title))", description: "\(escGraphQL(description))", teamId: "\(teamId)" }) {
                success
                issue { identifier url }
              }
            }
            """
        guard let result = try? await linearGraphQL(query: mutation, token: token) else {
            return ["error": "Linear request failed"]
        }
        if let data = result["data"] as? [String: Any],
            let issueCreate = data["issueCreate"] as? [String: Any],
            let issue = issueCreate["issue"] as? [String: Any]
        {
            return ["result": "created \(issue["identifier"] ?? "issue")", "url": issue["url"] ?? ""]
        }
        return ["error": "Linear did not confirm issue creation", "response": result]
    }

    private static func escGraphQL(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func linearGraphQL(query: String, token: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query])
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // MARK: - System utilities

    @MainActor
    private static func takeScreenshot() -> [String: Any] {
        let dir = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let path = dir.appendingPathComponent("VoxOS-Screenshot-\(Int(Date().timeIntervalSince1970)).png").path
        let task = Process()
        task.launchPath = "/usr/sbin/screencapture"
        task.arguments = ["-x", path]
        try? task.run()
        task.waitUntilExit()
        return FileManager.default.fileExists(atPath: path)
            ? ["result": "saved screenshot", "path": path]
            : ["error": "screenshot failed"]
    }

    // MARK: - Media control

    @MainActor
    static func mediaKey(action: String) -> [String: Any] {
        let normalized = action.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return ["error": "action is required"] }
        guard PlaybackController.shared.performAgentMediaAction(normalized) else {
            return ["error": "unknown media action \(normalized); use play, pause, toggle, next, or previous"]
        }
        return ["result": "media \(normalized)"]
    }

    // MARK: - Slack (UI automation via System Events; draft-safe, user presses Return to send)

    @MainActor
    static func slackSend(to: String, text: String) -> [String: Any] {
        let script = """
            tell application "Slack" to activate
            delay 0.6
            tell application "System Events"
              tell process "Slack"
                keystroke "k" using {command down}
                delay 0.4
                keystroke "\(esc(to))"
                delay 0.6
                key code 36
                delay 0.6
                keystroke "\(esc(text))"
              end tell
            end tell
            return "ok"
            """
        let result = AgentAppleScript.run(script)
        if result["error"] == nil {
            return ["result": "opened Slack DM/channel for \(to) with the message typed — press Return to send"]
        }
        return result
    }

    // MARK: - Contacts (read-only lookup)

    @MainActor
    static func contactsFind(name: String) -> [String: Any] {
        guard !name.isEmpty else { return ["error": "name is required"] }
        let script = """
            set output to ""
            tell application "Contacts"
              set matches to (every person whose name contains "\(esc(name))")
              repeat with p in matches
                set line_ to (name of p)
                repeat with ph in (phones of p)
                  set line_ to line_ & " | phone: " & (value of ph)
                end repeat
                repeat with em in (emails of p)
                  set line_ to line_ & " | email: " & (value of em)
                end repeat
                set output to output & line_ & linefeed
              end repeat
            end tell
            if output is "" then return "No contact found matching \(esc(name))."
            return output
            """
        return AgentAppleScript.run(script)
    }

    // MARK: - Messages (iMessage; executes only after voice confirmation)

    @MainActor
    static func messagesSend(to: String, text: String) -> [String: Any] {
        let script = """
            tell application "Messages"
              set targetService to 1st account whose service type = iMessage
              set targetBuddy to participant "\(esc(to))" of targetService
              send "\(esc(text))" to targetBuddy
              return "sent"
            end tell
            """
        let result = AgentAppleScript.run(script)
        if result["error"] != nil {
            let fallback = """
                tell application "Messages"
                  send "\(esc(text))" to buddy "\(esc(to))" of (1st account whose service type = iMessage)
                  return "sent"
                end tell
                """
            return AgentAppleScript.run(fallback)
        }
        return result
    }
}

/// Tiny persistent key-value memory for the agent, stored next to VoxOS's data.
enum AgentMemory {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.achyuthkp.VoxOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("AgentMemory.json")
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL),
            let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    private static func save(_ dict: [String: String]) {
        if let data = try? JSONEncoder().encode(dict) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    static func remember(key: String, value: String) -> [String: Any] {
        guard !key.isEmpty else { return ["error": "key is required"] }
        var dict = load()
        dict[key.lowercased()] = value
        save(dict)
        return ["result": "remembered \(key)"]
    }

    static func recall(key: String) -> [String: Any] {
        let dict = load()
        guard !key.isEmpty else {
            return ["keys": Array(dict.keys).sorted()]
        }
        let q = key.lowercased()
        if let exact = dict[q] { return ["value": exact] }
        let fuzzy = dict.filter { $0.key.contains(q) }
        if fuzzy.isEmpty { return ["result": "nothing remembered for \(key)"] }
        return ["matches": fuzzy]
    }
}
