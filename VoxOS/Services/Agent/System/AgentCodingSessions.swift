import AppKit
import Foundation

/// Recent Claude Code sessions, read from the files the CLI keeps under ~/.claude/projects, and a
/// way to pick one up again in Terminal. Codex keeps no sessions on this machine, so it is not
/// listed; the tool says so rather than returning an empty list that looks like "none".
enum AgentCodingSessions {
    struct Session: Equatable {
        let id: String
        let project: String
        let title: String
        let modified: Date
    }

    static let maxSessions = 8
    /// A session file can be megabytes; only its head is read for the title.
    static let titleScanBytes = 64_000

    static var projectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// The first thing the user typed, from the file's JSON lines. Only `user` records with plain
    /// string content count: tool results carry arrays, and injected prompts start with a tag.
    static func title(fromLines lines: [String]) -> (title: String, cwd: String?)? {
        for line in lines {
            guard let data = line.data(using: .utf8),
                let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                record["type"] as? String == "user",
                let message = record["message"] as? [String: Any],
                let content = message["content"] as? String
            else { continue }
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("<") else { continue }
            let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
            return (String(firstLine.prefix(80)), record["cwd"] as? String)
        }
        return nil
    }

    /// "-Users-name-project" is how the CLI names a project folder; the real path comes from the
    /// session file when it has one, this is the fallback.
    static func decodeProjectFolder(_ folder: String) -> String {
        folder.hasPrefix("-") ? folder.replacingOccurrences(of: "-", with: "/") : folder
    }

    static func headLines(of url: URL, maxBytes: Int = titleScanBytes) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes)) ?? Data()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    static func list(limit: Int = maxSessions) -> [Session] {
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil) else {
            return []
        }
        var found: [(folder: String, file: URL, modified: Date)] = []
        for project in projects {
            guard
                let files = try? fm.contentsOfDirectory(
                    at: project, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            for file in files where file.pathExtension == "jsonl" {
                let modified =
                    (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? .distantPast
                found.append((project.lastPathComponent, file, modified))
            }
        }
        return found.sorted { $0.modified > $1.modified }.prefix(limit).map { entry in
            let info = title(fromLines: headLines(of: entry.file))
            return Session(
                id: entry.file.deletingPathExtension().lastPathComponent,
                project: info?.cwd ?? decodeProjectFolder(entry.folder),
                title: info?.title ?? "(no prompt yet)",
                modified: entry.modified)
        }
    }

    static func listTool() -> [String: Any] {
        let sessions = list()
        guard !sessions.isEmpty else {
            return ["sessions": [], "note": "No Claude Code sessions found under ~/.claude/projects."]
        }
        let formatter = RelativeDateTimeFormatter()
        return [
            "sessions": sessions.map {
                [
                    "id": $0.id, "project": $0.project, "title": $0.title,
                    "last_used": formatter.localizedString(for: $0.modified, relativeTo: Date()),
                ]
            },
            "note": "Codex is not installed, so only Claude Code sessions are listed.",
        ]
    }

    /// Opens Terminal in the session's project and resumes it there. The user sees and controls the CLI.
    @MainActor
    static func resume(id: String) -> [String: Any] {
        let id = id.trimmingCharacters(in: .whitespaces)
        guard id.range(of: "^[0-9a-fA-F-]{4,}$", options: .regularExpression) != nil else {
            return ["error": "a session id looks like 3bde11c3-…; call coding_sessions first"]
        }
        guard let session = list(limit: 50).first(where: { $0.id == id || $0.id.hasPrefix(id) }) else {
            return ["error": "no session with id \(id)"]
        }
        let script = """
            tell application "Terminal"
              activate
              do script "cd " & quoted form of "\(AgentMusic.escape(session.project))" & " && claude --resume \(session.id)"
            end tell
            """
        let result = AgentAppleScript.run(script)
        if let error = result["error"] { return ["error": error] }
        return ["result": "resumed in Terminal", "title": session.title, "project": session.project]
    }
}
