import AppKit
import Foundation

/// "Remind me to send the invoice when I open Slack." Nudges fire as a VoxOS toast when the
/// named app comes to the front, or at a time, and stay until marked done — an ignored nudge
/// comes back on a later switch to that app, never more often than `refireInterval`.
struct AgentNudge: Codable, Identifiable, Equatable {
    let id: UUID
    let text: String
    let appName: String?
    let bundleID: String?
    let due: Date?
    let createdAt: Date
    var lastShownAt: Date?

    static let refireInterval: TimeInterval = 10 * 60

    /// Whether this nudge should show now, given the app that just came forward (if any).
    func shouldFire(activatedBundleID: String?, now: Date) -> Bool {
        if let lastShownAt, now.timeIntervalSince(lastShownAt) < Self.refireInterval { return false }
        if let bundleID {
            // App nudges wait for the app, and for their time if they also have one.
            guard activatedBundleID == bundleID else { return false }
            return due.map { now >= $0 } ?? true
        }
        guard let due else { return false }
        return now >= due
    }
}

@MainActor
final class AgentNudges {
    static let shared = AgentNudges()

    private(set) var nudges: [AgentNudge] = []
    private var activationObserver: NSObjectProtocol?
    private var timer: Timer?
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.achyuthkp.VoxOS", isDirectory: true)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            self.fileURL = base.appendingPathComponent("nudges.json")
        }
        load()
    }

    func start() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in AgentNudges.shared.check(activatedBundleID: app?.bundleIdentifier) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in AgentNudges.shared.check(activatedBundleID: nil) }
        }
    }

    // MARK: - Editing

    func add(text: String, appName: String?, due: Date?) -> Result<AgentNudge, NudgeError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.missingText) }

        var resolvedName: String?
        var bundleID: String?
        if let appName, !appName.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let match = Self.resolveApp(appName) else { return .failure(.appNotFound(appName)) }
            resolvedName = match.name
            bundleID = match.bundleID
        }
        guard bundleID != nil || due != nil else { return .failure(.missingTrigger) }

        let nudge = AgentNudge(
            id: UUID(), text: trimmed, appName: resolvedName, bundleID: bundleID, due: due, createdAt: Date(),
            lastShownAt: nil)
        nudges.append(nudge)
        save()
        return .success(nudge)
    }

    @discardableResult
    func complete(matching query: String) -> AgentNudge? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard
            let index = nudges.firstIndex(where: {
                $0.id.uuidString.lowercased().hasPrefix(q) || (!q.isEmpty && $0.text.lowercased().contains(q))
            })
        else { return nil }
        let removed = nudges.remove(at: index)
        save()
        return removed
    }

    func complete(id: UUID) {
        nudges.removeAll { $0.id == id }
        save()
    }

    // MARK: - Firing

    func check(activatedBundleID: String?, now: Date = Date()) {
        guard let index = nudges.firstIndex(where: { $0.shouldFire(activatedBundleID: activatedBundleID, now: now) })
        else {
            return
        }
        nudges[index].lastShownAt = now
        save()
        let nudge = nudges[index]
        NotificationManager.shared.showNotification(
            title: nudge.text,
            type: .info,
            duration: 10,
            actionButton: (label: String(localized: "Done"), action: { AgentNudges.shared.complete(id: nudge.id) })
        )
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        nudges = (try? decoder.decode([AgentNudge].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(nudges).write(to: fileURL, options: .atomic)
    }

    // MARK: - Helpers

    enum NudgeError: Error, Equatable {
        case missingText
        case missingTrigger
        case appNotFound(String)

        var message: String {
            switch self {
            case .missingText: return "text is required"
            case .missingTrigger: return "give when_app, at, or both"
            case .appNotFound(let name): return "no installed app matches \(name)"
            }
        }
    }

    nonisolated static func resolveApp(_ name: String) -> (name: String, bundleID: String)? {
        let names = AgentQuickIntents.installedAppNames()
        guard let match = AgentQuickIntents.bestMatch(for: name.lowercased(), in: names) else { return nil }
        for directory in [
            "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
        ] {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(match + ".app")
            if let bundleID = Bundle(url: url)?.bundleIdentifier { return (match, bundleID) }
        }
        return nil
    }

    nonisolated static func parseDue(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: raw.trimmingCharacters(in: .whitespaces))
    }

    func toolList() -> [String: Any] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return [
            "nudges": nudges.map { nudge -> [String: Any] in
                var entry: [String: Any] = ["id": String(nudge.id.uuidString.prefix(8)), "text": nudge.text]
                if let app = nudge.appName { entry["when_app"] = app }
                if let due = nudge.due { entry["at"] = formatter.string(from: due) }
                return entry
            }
        ]
    }
}
