import Combine
import Foundation

/// Codex in the notch: a notice when a Codex turn ends, through Codex's own `notify` setting.
///
/// Codex runs the `notify` program with the event's JSON as its last argument, so the program is
/// curl itself with `--data-binary` last: the JSON lands as the body sent to the bridge. Codex
/// has no hook that can answer an approval, so this says when a turn is done, nothing more. A
/// `notify` the user set is never replaced; the line VoxOS adds is recognised by the bridge's
/// path and is the only thing ever removed.
enum CodexNotify {
    static let path = "/voxos/codex/notify"

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/config.toml")
    }

    /// The CLI keeps its settings in ~/.codex.
    static var codexInstalled: Bool {
        FileManager.default.fileExists(atPath: configURL.deletingLastPathComponent().path)
    }

    static func line(port: UInt16) -> String {
        let arguments = [
            "/usr/bin/curl", "-sf", "-m", "2", "-X", "POST", "-H", "\(ClaudeCodeBridge.markerHeader): 1", "-H",
            "Content-Type: application/json", "http://127.0.0.1:\(port)\(path)", "--data-binary",
        ]
        return "notify = [" + arguments.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
    }

    /// A top-level `notify` of the user's own: before the first table header.
    static func hasOwnNotify(_ toml: String) -> Bool {
        for line in toml.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { return false }
            if trimmed.range(of: #"^notify\s*="#, options: .regularExpression) != nil, !trimmed.contains(path) {
                return true
            }
        }
        return false
    }

    static func isInstalled(_ toml: String) -> Bool { toml.contains(path) }

    /// The config with VoxOS's line first (top-level keys must come before any table), or nil
    /// when it is there already or the user has a notify of their own.
    static func installing(into toml: String, port: UInt16) -> String? {
        guard !isInstalled(toml), !hasOwnNotify(toml) else { return nil }
        return line(port: port) + "\n" + toml
    }

    static func removing(from toml: String) -> String {
        toml.components(separatedBy: "\n").filter { !$0.contains(path) }.joined(separator: "\n")
    }

    static func install(port: UInt16, at url: URL = configURL) throws {
        let toml = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard let updated = installing(into: toml, port: port) else { return }
        try write(updated, to: url)
    }

    static func uninstall(at url: URL = configURL) throws {
        guard let toml = try? String(contentsOf: url, encoding: .utf8), isInstalled(toml) else { return }
        try write(removing(from: toml), to: url)
    }

    /// After copying the previous file to config.toml.voxos-backup, like Claude Code's settings.
    private static func write(_ toml: String, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: url.path) {
            let backup = url.appendingPathExtension("voxos-backup")
            try? fm.removeItem(at: backup)
            try fm.copyItem(at: url, to: backup)
        }
        try Data(toml.utf8).write(to: url, options: .atomic)
    }
}

/// The notice for a Codex turn that ended.
@MainActor
final class CodexActivity: ObservableObject {
    static let shared = CodexActivity()
    static let noticeLifetime: TimeInterval = 4

    @Published private(set) var notice: NotchHome.Notice?
    private var clearTask: Task<Void, Never>?

    private init() {}

    struct TurnEnd: Equatable {
        /// The folder Codex ran in, when the event says.
        let project: String?
    }

    /// Codex's agent-turn-complete event; others are ignored.
    nonisolated static func turnEnd(from object: [String: Any]) -> TurnEnd? {
        guard object["type"] as? String == "agent-turn-complete" else { return nil }
        return TurnEnd(project: (object["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent })
    }

    func turnEnded(project: String?) {
        notice = NotchHome.Notice(
            symbol: "checkmark.circle.fill", title: "Codex", detail: project ?? String(localized: "Done"))
        clearTask?.cancel()
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.noticeLifetime))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
