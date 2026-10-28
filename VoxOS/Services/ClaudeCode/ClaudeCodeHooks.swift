import Foundation

/// Adds VoxOS's hooks to Claude Code's user settings, and takes them out again.
///
/// Each hook is a command that pipes the event to the bridge with /usr/bin/curl and swallows any
/// failure. A `type: "http"` hook would do the same with less, but when VoxOS is not running the
/// CLI prints "hook error: connect ECONNREFUSED" under every tool call; a curl that fails quietly
/// prints nothing (measured on 2.1.312, ADR 0006).
///
/// The merge and removal are pure functions over the settings dictionary, so the rule that
/// matters most — the user's own hooks are never touched — is tested without the real file.
/// A VoxOS hook is recognised by the bridge's URL path in its command alone; nothing else in the
/// file is ever rewritten except that keys come back sorted.
enum ClaudeCodeHooks {
    static let path = "/voxos/claude-code/hook"

    /// Status events: answered at once, so a short timeout only matters if VoxOS hangs.
    static let statusEvents: [ClaudeCodeHookEvent.Kind] = [
        .sessionStart, .sessionEnd, .userPromptSubmit, .preToolUse, .postToolUse, .postToolUseFailure,
        .notification, .stop, .stopFailure,
    ]
    static let statusTimeout = 5
    /// How long the CLI holds a permission request open for the notch; its own default.
    static let permissionTimeout = 600

    static var events: [ClaudeCodeHookEvent.Kind] { statusEvents + [.permissionRequest] }

    static func url(port: UInt16) -> String { "http://127.0.0.1:\(port)\(path)" }

    /// curl gives up a little before the CLI would kill it, so it always exits on its own terms.
    /// `$PPID` is the CLI process that ran the hook's shell: VoxOS watches it, so a session whose
    /// CLI was killed (and so never sends SessionEnd) leaves the notch.
    static func command(for event: ClaudeCodeHookEvent.Kind, port: UInt16) -> String {
        let maxTime = event == .permissionRequest ? permissionTimeout - 10 : statusTimeout - 1
        return "/usr/bin/curl -sf -m \(maxTime) -X POST -H 'Content-Type: application/json' "
            + "-H '\(ClaudeCodeBridge.markerHeader): 1' -H \"\(ClaudeCodeBridge.pidHeader): $PPID\" "
            + "--data-binary @- \(url(port: port)) || true"
    }

    static func hook(for event: ClaudeCodeHookEvent.Kind, port: UInt16) -> [String: Any] {
        [
            "type": "command",
            "command": command(for: event, port: port),
            "timeout": event == .permissionRequest ? permissionTimeout : statusTimeout,
        ]
    }

    static func isVoxOSHook(_ hook: Any) -> Bool { isHook(hook, posting: path) }

    /// A hook whose command (or URL) posts to the bridge at `path`. Gemini CLI's settings use the
    /// same shape, with its own path.
    static func isHook(_ hook: Any, posting path: String) -> Bool {
        guard let hook = hook as? [String: Any] else { return false }
        return [hook["command"], hook["url"]].contains { ($0 as? String)?.contains(path) == true }
    }

    // MARK: Pure merge

    /// The settings with every VoxOS hook removed. Matcher groups left empty are dropped, and so
    /// is an event left with no groups, and `hooks` itself when nothing remains in it.
    static func removing(from settings: [String: Any], posting path: String = path) -> [String: Any] {
        guard let hooks = settings["hooks"] as? [String: Any] else { return settings }
        var cleaned: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                cleaned[event] = value
                continue
            }
            var kept: [[String: Any]] = []
            for group in groups {
                guard let entries = group["hooks"] as? [Any] else {
                    kept.append(group)
                    continue
                }
                let remaining = entries.filter { !isHook($0, posting: path) }
                if remaining.count == entries.count {
                    kept.append(group)
                } else if !remaining.isEmpty {
                    var trimmed = group
                    trimmed["hooks"] = remaining
                    kept.append(trimmed)
                }
            }
            if !kept.isEmpty { cleaned[event] = kept }
        }
        var result = settings
        result["hooks"] = cleaned.isEmpty ? nil : cleaned
        return result
    }

    /// The settings with exactly one VoxOS hook group per event, pointing at `port`.
    static func installing(into settings: [String: Any], port: UInt16) -> [String: Any] {
        var result = removing(from: settings)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var groups = hooks[event.rawValue] as? [[String: Any]] ?? []
            groups.append(["hooks": [hook(for: event, port: port)]])
            hooks[event.rawValue] = groups
        }
        result["hooks"] = hooks
        return result
    }

    enum InstallState: Equatable {
        case notInstalled
        case installed
        /// Some events are missing, or the hooks point at another port.
        case outdated
    }

    static func state(of settings: [String: Any], port: UInt16) -> InstallState {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        var found = 0
        var current = 0
        for event in events {
            let entries = (hooks[event.rawValue] as? [[String: Any]] ?? [])
                .flatMap { $0["hooks"] as? [Any] ?? [] }
                .filter(isVoxOSHook)
            if !entries.isEmpty { found += 1 }
            if entries.contains(where: { hook in
                (hook as? [String: Any])?["command"] as? String == command(for: event, port: port)
            }) {
                current += 1
            }
        }
        if found == 0 { return .notInstalled }
        return current == events.count ? .installed : .outdated
    }

    // MARK: File

    enum FileError: LocalizedError {
        case unreadable(URL, String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let url, let reason):
                let file = (url.path as NSString).abbreviatingWithTildeInPath
                return String(localized: "\(file) could not be read: \(reason)")
            }
        }
    }

    static var userSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    /// A missing file reads as empty settings. A file that is not a JSON object throws, so it is
    /// never overwritten with VoxOS's hooks alone.
    static func read(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FileError.unreadable(url, error.localizedDescription)
        }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FileError.unreadable(url, String(localized: "it is not valid JSON"))
        }
        return object
    }

    /// Writes atomically, after copying the previous file to settings.json.voxos-backup, and keeps
    /// the file's permissions.
    static func write(_ settings: [String: Any], to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var permissions: Any?
        if fm.fileExists(atPath: url.path) {
            permissions = try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]
            let backup = url.appendingPathExtension("voxos-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
        }
        var data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
        if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
    }

    static func install(port: UInt16, at url: URL = userSettingsURL) throws {
        try write(installing(into: read(at: url), port: port), to: url)
    }

    static func uninstall(at url: URL = userSettingsURL) throws {
        let settings = try read(at: url)
        guard state(of: settings, port: 0) != .notInstalled else { return }
        try write(removing(from: settings), to: url)
    }

    static func state(at url: URL = userSettingsURL, port: UInt16) throws -> InstallState {
        try state(of: read(at: url), port: port)
    }
}
