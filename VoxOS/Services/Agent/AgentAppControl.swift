import AppKit
import Foundation

/// Per-app control modes: the user can let the agent act freely in one app, ask first in
/// another and only watch in a third. The global `AgentControlMode.current` stays the
/// default and the only mode for tools that are not about one app (shell, AppleScript,
/// files, plugins, MCP, clipboard, the mode switch itself).
extension AgentControlMode {

    static let appOverridesKey = "agentControlModeAppOverrides"

    /// bundle id → mode. Unknown raw values are dropped, never read as takeover.
    static var appOverrides: [String: AgentControlMode] {
        get {
            let raw = UserDefaults.standard.dictionary(forKey: appOverridesKey) as? [String: String] ?? [:]
            return raw.compactMapValues(AgentControlMode.init(rawValue:))
        }
        set {
            UserDefaults.standard.set(newValue.mapValues(\.rawValue), forKey: appOverridesKey)
        }
    }

    static func setOverride(_ mode: AgentControlMode?, forBundleID bundleID: String) {
        var overrides = appOverrides
        overrides[bundleID] = mode
        appOverrides = overrides
    }

    /// The app's own mode when it has one, otherwise the global mode.
    static func effectiveMode(forBundleID bundleID: String?) -> AgentControlMode {
        guard let bundleID, let mode = appOverrides[bundleID] else { return current }
        return mode
    }

    /// The mode that decides whether `tool` may run with `args` right now.
    static func mode(forTool tool: String, args: [String: Any]) -> AgentControlMode {
        effectiveMode(forBundleID: targetBundleID(forTool: tool, args: args))
    }

    /// The stricter of two modes; used when a held action is confirmed later.
    static func stricter(_ a: AgentControlMode, _ b: AgentControlMode) -> AgentControlMode {
        a.rank <= b.rank ? a : b
    }

    /// Tools that act on whatever app is in front: clicks, typing, keys, browser actions.
    static let frontmostAppTools: Set<String> = [
        "click_element", "click_text", "click_mark", "mouse_click", "mouse_move", "mouse_drag", "scroll",
        "type_text", "press_key", "hotkey", "undo_last_action",
        "browser_click_text", "browser_run_js", "switch_browser_tab",
    ]

    /// Tools that always talk to one app, wherever focus is.
    static let fixedAppTools: [String: String] = [
        "mail_compose": "com.apple.mail", "mail_send_confirmed": "com.apple.mail",
        "messages_send": "com.apple.MobileSMS", "messages_send_confirmed": "com.apple.MobileSMS",
        "messages_recent": "com.apple.MobileSMS",
        "notes_create": "com.apple.Notes",
        "calendar_add_event": "com.apple.iCal",
        "reminders_add": "com.apple.reminders",
        "music_play": "com.apple.Music", "music_control": "com.apple.Music",
        "slack_send": "com.tinyspeck.slackmacgap", "slack_send_confirmed": "com.tinyspeck.slackmacgap",
        "whatsapp_send": "net.whatsapp.WhatsApp",
        "telegram_send": "ru.keepcoder.Telegram",
        "obsidian_note": "md.obsidian",
    ]

    /// Which app a tool call acts on, or nil when it is not about one app (then the global
    /// mode applies). An app name that cannot be resolved also gives nil — never the
    /// frontmost app, which would let "open 1Password" borrow the mode of whatever is in front.
    static func targetBundleID(forTool tool: String, args: [String: Any]) -> String? {
        if frontmostAppTools.contains(tool) { return AgentFrontmostApp.bundleID }
        if let fixed = fixedAppTools[tool] { return fixed }
        switch tool {
        case "open_app", "activate_app":
            return AgentAppResolver.bundleID(forName: (args["name"] as? String) ?? "")
        case "set_window_bounds":
            return AgentAppResolver.bundleID(forName: (args["app"] as? String) ?? "")
        default:
            return nil
        }
    }

    /// The overrides as the model sees them in the runtime section, by app name.
    static func overridesSummary() -> String? {
        let overrides = appOverrides
        guard !overrides.isEmpty else { return nil }
        return
            overrides
            .map { "\(AgentAppResolver.displayName(forBundleID: $0.key)) = \($0.value.rawValue)" }
            .sorted()
            .joined(separator: ", ")
    }
}

/// The app the agent's UI actions land in: the last app other than VoxOS that came to the
/// front. VoxOS's own panel is skipped because it is in front while the user talks to it.
/// `open_app`/`activate_app` write it synchronously, so a batch that activates an app and
/// types 300 ms later is checked against the app it activated, not the one before it.
enum AgentFrontmostApp {
    private static let lock = NSLock()
    private static var cached: String?
    private static var observer: NSObjectProtocol?

    static var bundleID: String? {
        startObserving()
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    static func set(_ bundleID: String?) {
        guard let bundleID, bundleID != Bundle.main.bundleIdentifier else { return }
        lock.lock()
        defer { lock.unlock() }
        cached = bundleID
    }

    private static func startObserving() {
        lock.lock()
        let needsStart = observer == nil
        if needsStart {
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
            ) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                set(app.bundleIdentifier)
            }
        }
        lock.unlock()
        if needsStart, let app = NSWorkspace.shared.frontmostApplication,
            app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        {
            set(app.bundleIdentifier)
        }
    }
}

/// App name → bundle id, the same way `AgentWindows` finds apps: running apps first, then
/// a bundle id spelled out, then the usual application folders.
enum AgentAppResolver {

    static func bundleID(forName name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let q = trimmed.lowercased()
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        if let app = running.first(where: { $0.localizedName?.lowercased() == q || $0.bundleIdentifier?.lowercased() == q })
            ?? running.first(where: { $0.localizedName?.lowercased().contains(q) ?? false }),
            let id = app.bundleIdentifier
        {
            return id
        }
        if trimmed.contains("."), !trimmed.hasSuffix(".app"), !trimmed.contains(" ") { return trimmed }
        let base = trimmed.hasSuffix(".app") ? String(trimmed.dropLast(4)) : trimmed
        for directory in [
            "/Applications", "/System/Applications", "/System/Applications/Utilities",
            "\(NSHomeDirectory())/Applications",
        ] {
            let url = URL(fileURLWithPath: "\(directory)/\(base).app")
            if let id = Bundle(url: url)?.bundleIdentifier { return id }
        }
        return nil
    }

    static func displayName(forBundleID bundleID: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }
}
