import Combine
import Foundation

/// Claude's usage limits (the 5-hour and weekly windows) and what sessions cost, from what
/// Claude Code hands its status line.
///
/// The status line command gets a JSON object on every refresh, with `rate_limits` for
/// subscribers and the session's `cost` (measured on 2.1.312's schema). Switched on, VoxOS wraps
/// the user's own status line command so the same input is also sent to the bridge; the
/// original command still prints the status line, and switching off puts it back exactly. The
/// limits warn in the notch as they run high; costs are kept per day, by session, in a small
/// file beside VoxOS's other data.
@MainActor
final class ClaudeCodeUsage: ObservableObject {
    static let shared = ClaudeCodeUsage()

    struct Window: Equatable {
        let percent: Double
        let resetsAt: Date
    }

    /// Notch notices as the 5-hour window passes these.
    nonisolated static let warnings: [Double] = [80, 95]
    static let noticeLifetime: TimeInterval = 4

    @Published private(set) var fiveHour: Window?
    @Published private(set) var sevenDay: Window?
    /// Day ("yyyy-MM-dd", local) to session to its cost so far, in US dollars.
    @Published private(set) var costs: [String: [String: Double]] = [:]
    @Published private(set) var notice: NotchHome.Notice?

    private let storeURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.achyuthkp.VoxOS/claude-code-costs.json")
    private var saveTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?

    private init() {
        if let data = try? Data(contentsOf: storeURL),
            let saved = try? JSONDecoder().decode([String: [String: Double]].self, from: data)
        {
            costs = saved
        }
    }

    struct Reading: Equatable {
        var sessionID: String?
        var fiveHour: Window?
        var sevenDay: Window?
        var costUSD: Double?
    }

    nonisolated static func reading(from object: [String: Any]) -> Reading {
        func window(_ key: String) -> Window? {
            guard let limits = object["rate_limits"] as? [String: Any], let entry = limits[key] as? [String: Any],
                let percent = (entry["used_percentage"] as? NSNumber)?.doubleValue,
                let resets = (entry["resets_at"] as? NSNumber)?.doubleValue
            else { return nil }
            return Window(percent: percent, resetsAt: Date(timeIntervalSince1970: resets))
        }
        return Reading(
            sessionID: object["session_id"] as? String, fiveHour: window("five_hour"), sevenDay: window("seven_day"),
            costUSD: ((object["cost"] as? [String: Any])?["total_cost_usd"] as? NSNumber)?.doubleValue)
    }

    func receive(_ reading: Reading, now: Date = Date()) {
        if let window = reading.fiveHour {
            if Self.crossed(from: fiveHour?.percent, to: window.percent) != nil {
                post(
                    NotchHome.Notice(
                        symbol: "gauge.with.dots.needle.67percent", title: String(localized: "Claude 5-hour limit"),
                        detail: "\(Int(window.percent))%"))
            }
            if fiveHour != window { fiveHour = window }
        }
        if let window = reading.sevenDay, sevenDay != window { sevenDay = window }
        if let session = reading.sessionID, let cost = reading.costUSD {
            let day = Self.day(now)
            // A session's cost only grows; a smaller one is a new session reusing nothing.
            if costs[day, default: [:]][session].map({ cost > $0 }) ?? true {
                costs[day, default: [:]][session] = cost
                scheduleSave()
            }
        }
    }

    /// The warning level a rise from `old` to `new` passes, if any.
    nonisolated static func crossed(from old: Double?, to new: Double) -> Double? {
        warnings.last { new >= $0 && (old ?? 0) < $0 }
    }

    nonisolated static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Dollars over the last `days` days, today included.
    func total(days: Int, now: Date = Date(), calendar: Calendar = .current) -> Double {
        (0..<days).compactMap { calendar.date(byAdding: .day, value: -$0, to: now) }
            .map { costs[Self.day($0, calendar: calendar)]?.values.reduce(0, +) ?? 0 }
            .reduce(0, +)
    }

    private func post(_ notice: NotchHome.Notice) {
        self.notice = notice
        clearTask?.cancel()
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.noticeLifetime))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// Written at most every few seconds, as the status line refreshes often.
    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            self.saveTask = nil
            // A year of days is plenty; older ones go.
            let keep = Set(self.costs.keys.sorted().suffix(366))
            self.costs = self.costs.filter { keep.contains($0.key) }
            try? FileManager.default.createDirectory(
                at: self.storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(self.costs).write(to: self.storeURL, options: .atomic)
        }
    }
}

/// Wraps the user's status line command so its input also reaches the bridge, and unwraps it.
/// Pure functions over the settings dictionary, like ClaudeCodeHooks, so the rule that matters —
/// the user's command comes back exactly — is tested without the real file.
enum ClaudeCodeStatusRelay {
    static let path = "/voxos/claude-code/status"

    static func url(port: UInt16) -> String { "http://127.0.0.1:\(port)\(path)" }

    /// Reads the input once, sends a copy in the background (failing quietly when VoxOS is not
    /// running), and hands the same input to the original command, whose output is the line.
    static func command(wrapping original: String?, port: UInt16) -> String {
        let send =
            "printf '%s' \"$input\" | /usr/bin/curl -sf -m 2 -X POST -H 'Content-Type: application/json' "
            + "-H '\(ClaudeCodeBridge.markerHeader): 1' --data-binary @- \(url(port: port)) >/dev/null 2>&1 &"
        let rest = original.map { " printf '%s' \"$input\" | \($0)" } ?? " true"
        return "input=$(cat); " + send + rest
    }

    static func isRelay(_ statusLine: Any?) -> Bool {
        ((statusLine as? [String: Any])?["command"] as? String)?.contains(path) == true
    }

    /// The settings with the status line wrapped, and the original status line to keep.
    static func installing(into settings: [String: Any], port: UInt16) -> (
        settings: [String: Any], original: [String: Any]?
    )? {
        guard !isRelay(settings["statusLine"]) else { return nil }
        let original = settings["statusLine"] as? [String: Any]
        let originalCommand = original.flatMap { $0["type"] as? String == "command" ? $0["command"] as? String : nil }
        var line = original ?? [:]
        line["type"] = "command"
        line["command"] = command(wrapping: originalCommand, port: port)
        var result = settings
        result["statusLine"] = line
        return (result, original)
    }

    /// The settings with the user's own status line back, or none if there was none.
    static func removing(from settings: [String: Any], original: [String: Any]?) -> [String: Any] {
        guard isRelay(settings["statusLine"]) else { return settings }
        var result = settings
        result["statusLine"] = original
        return result
    }

    static func install(port: UInt16, at url: URL = ClaudeCodeHooks.userSettingsURL) throws {
        let settings = try ClaudeCodeHooks.read(at: url)
        guard let (wrapped, original) = installing(into: settings, port: port) else { return }
        UserDefaults.standard.set(
            original.flatMap { try? JSONSerialization.data(withJSONObject: $0) },
            forKey: DefaultsKeys.claudeCodeOriginalStatusLine)
        try ClaudeCodeHooks.write(wrapped, to: url)
    }

    static func uninstall(at url: URL = ClaudeCodeHooks.userSettingsURL) throws {
        let settings = try ClaudeCodeHooks.read(at: url)
        guard isRelay(settings["statusLine"]) else { return }
        let original = UserDefaults.standard.data(forKey: DefaultsKeys.claudeCodeOriginalStatusLine)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        try ClaudeCodeHooks.write(removing(from: settings, original: original), to: url)
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.claudeCodeOriginalStatusLine)
    }
}
