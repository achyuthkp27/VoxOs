import Combine
import Foundation

/// When a Claude Code session pushes, the notch says how that push's CI run ended.
///
/// A PostToolUse for a Bash command that ran `git push` starts a watch on the session's folder:
/// GitHub's own CLI (`gh run list`, through the login shell so it is found wherever it is
/// installed) is asked once a minute for the newest run started after the push, until it
/// completes or 45 minutes pass. Nothing runs between pushes; without gh, or outside a GitHub
/// repository, the watch simply ends.
@MainActor
final class ClaudeCodeCIWatch: ObservableObject {
    static let shared = ClaudeCodeCIWatch()

    struct Run: Equatable {
        let completed: Bool
        let conclusion: String?
        let created: Date
    }

    static let firstLook: TimeInterval = 20
    static let interval: TimeInterval = 60
    static let attempts = 45
    static let noticeLifetime: TimeInterval = 5

    @Published private(set) var notice: NotchHome.Notice?
    private var watches: [String: Task<Void, Never>] = [:]
    private var clearTask: Task<Void, Never>?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.claudeCodeCIEnabled) }

    private init() {}

    /// `git push` as its own command (options such as `-C repo` before it allowed), not a word
    /// inside another one.
    nonisolated static func isPush(_ command: String) -> Bool {
        command.range(
            of: #"(^|[;&|(]\s*|\s&&\s*)git\s+(-\S+\s+(?:[^-\s]\S*\s+)?)*push\b"#, options: .regularExpression)
            != nil
    }

    func pushed(in folder: String, at pushTime: Date = Date()) {
        guard Self.isEnabled, !ProcessIdentity.isTestHost, watches[folder] == nil else { return }
        ActivityTrail.mark("ci watch started")
        watches[folder] = Task { @MainActor [weak self] in
            defer { self?.watches[folder] = nil }
            try? await Task.sleep(for: .seconds(Self.firstLook))
            for _ in 0..<Self.attempts {
                guard !Task.isCancelled else { return }
                // A minute of slack for clocks and for the push that started this run.
                if let run = await Self.latestRun(in: folder), run.created >= pushTime.addingTimeInterval(-60),
                    run.completed
                {
                    self?.finished(run, in: folder)
                    return
                }
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    private func finished(_ run: Run, in folder: String) {
        let project = URL(fileURLWithPath: folder).lastPathComponent
        let passed = run.conclusion == "success"
        let detail: String
        switch run.conclusion {
        case "success": detail = String(localized: "CI passed")
        case "cancelled": detail = String(localized: "CI cancelled")
        default: detail = String(localized: "CI failed")
        }
        notice = NotchHome.Notice(
            symbol: passed ? "checkmark.seal.fill" : "xmark.octagon.fill", title: project, detail: detail)
        clearTask?.cancel()
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.noticeLifetime))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// The newest run in the folder's repository, from `gh run list`.
    nonisolated static func latestRun(in folder: String) async -> Run? {
        await Task.detached(priority: .utility) { () -> Run? in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [
                "-lc", #"cd "$1" && gh run list --limit 1 --json status,conclusion,createdAt"#, "voxos-ci", folder,
            ]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return run(fromJSON: data)
        }.value
    }

    nonisolated static func run(fromJSON data: Data) -> Run? {
        guard let first = (try? JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first,
            let created = (first["createdAt"] as? String).flatMap({ ISO8601DateFormatter().date(from: $0) })
        else { return nil }
        let conclusion = (first["conclusion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Run(completed: first["status"] as? String == "completed", conclusion: conclusion, created: created)
    }
}
