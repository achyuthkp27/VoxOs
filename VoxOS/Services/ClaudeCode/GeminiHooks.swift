import Combine
import Foundation

/// Gemini CLI in the notch: a notice when a turn ends, and one while a tool waits for approval,
/// through hooks in Gemini's user settings (~/.gemini/settings.json).
///
/// Gemini's `Notification` hook only reports a permission prompt; it cannot answer one, so the
/// notice says the terminal is waiting and goes when a tool runs, the turn ends or the session
/// closes. The hooks are commands shaped like Claude Code's: curl posts the event and stays
/// quiet, as Gemini reads a hook's output as its answer. VoxOS's hooks are recognised by the
/// bridge's path in their command, and nothing else in the file is changed.
enum GeminiHooks {
    static let path = "/voxos/gemini/hook"
    static let events = ["AfterAgent", "AfterTool", "Notification", "SessionEnd"]
    /// In milliseconds, as Gemini counts; curl gives up a second before.
    static let timeout = 3000

    static var settingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/settings.json")
    }

    /// The CLI keeps its settings in ~/.gemini.
    static var geminiInstalled: Bool {
        FileManager.default.fileExists(atPath: settingsURL.deletingLastPathComponent().path)
    }

    static func command(port: UInt16) -> String {
        "/usr/bin/curl -sf -m \(timeout / 1000 - 1) -o /dev/null -X POST -H 'Content-Type: application/json' "
            + "-H '\(ClaudeCodeBridge.markerHeader): 1' --data-binary @- http://127.0.0.1:\(port)\(path) || true"
    }

    static func isInstalled(_ settings: [String: Any]) -> Bool {
        let hooks = settings["hooks"] as? [String: Any] ?? [:]
        return hooks.values.contains { groups in
            (groups as? [[String: Any]] ?? []).flatMap { $0["hooks"] as? [Any] ?? [] }
                .contains { ClaudeCodeHooks.isHook($0, posting: path) }
        }
    }

    /// The settings with exactly one VoxOS hook per event, pointing at `port`.
    static func installing(into settings: [String: Any], port: UInt16) -> [String: Any] {
        var result = removing(from: settings)
        var hooks = result["hooks"] as? [String: Any] ?? [:]
        let hook: [String: Any] = [
            "name": "voxos", "type": "command", "command": command(port: port), "timeout": timeout,
        ]
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append(["hooks": [hook]])
            hooks[event] = groups
        }
        result["hooks"] = hooks
        return result
    }

    static func removing(from settings: [String: Any]) -> [String: Any] {
        ClaudeCodeHooks.removing(from: settings, posting: path)
    }

    /// Reading and writing are Claude Code's: a file that is not a JSON object (Gemini also
    /// accepts comments) is never rewritten, and the previous one is kept as a backup.
    static func install(port: UInt16, at url: URL = settingsURL) throws {
        try ClaudeCodeHooks.write(installing(into: ClaudeCodeHooks.read(at: url), port: port), to: url)
    }

    static func uninstall(at url: URL = settingsURL) throws {
        let settings = try ClaudeCodeHooks.read(at: url)
        guard isInstalled(settings) else { return }
        try ClaudeCodeHooks.write(removing(from: settings), to: url)
    }
}

/// The notices for Gemini CLI's turns and the approvals it waits for.
@MainActor
final class GeminiActivity: ObservableObject {
    static let shared = GeminiActivity()
    static let noticeLifetime: TimeInterval = 4
    /// An approval answered with a cancel sends nothing, so its notice leaves on its own.
    static let approvalLifetime: TimeInterval = 120

    @Published private(set) var notice: NotchHome.Notice?
    private var clearTask: Task<Void, Never>?

    init() {}

    enum Event: Equatable {
        case turnEnded(project: String?)
        /// Gemini's own words, such as "Tool Shell requires execution".
        case waiting(message: String)
        /// A tool ran or the session closed: nothing is waiting any more.
        case moved
    }

    nonisolated static func event(from object: [String: Any]) -> Event? {
        switch object["hook_event_name"] as? String {
        case "AfterAgent":
            return .turnEnded(project: (object["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent })
        case "Notification" where object["notification_type"] as? String == "ToolPermission":
            let message = (object["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .waiting(message: message.isEmpty ? String(localized: "Waiting in the terminal") : message)
        case "AfterTool", "SessionEnd":
            return .moved
        default:
            return nil
        }
    }

    func receive(_ event: Event) {
        switch event {
        case .turnEnded(let project):
            show(
                NotchHome.Notice(
                    symbol: "checkmark.circle.fill", title: "Gemini", detail: project ?? String(localized: "Done")),
                for: Self.noticeLifetime)
        case .waiting(let message):
            show(
                NotchHome.Notice(symbol: "hand.raised.fill", title: "Gemini", detail: message),
                for: Self.approvalLifetime)
        case .moved:
            // Only a waiting notice is out of date; a turn's end stays its few seconds.
            guard notice?.symbol == "hand.raised.fill" else { return }
            clearTask?.cancel()
            notice = nil
        }
    }

    private func show(_ notice: NotchHome.Notice, for lifetime: TimeInterval) {
        self.notice = notice
        clearTask?.cancel()
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(lifetime))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
