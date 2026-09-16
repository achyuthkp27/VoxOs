import AppKit
import Foundation

/// Deterministic fast path for the handful of requests that never need a model:
/// "open Chrome", "launch Slack", "what time is it". Runs before the LLM so a rate-limited
/// or slow provider cannot turn a two-word command into a timeout.
enum AgentQuickIntents {

    static func handle(_ transcript: String) async -> String? {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        let lower = text.lowercased()
        guard lower.count <= 60 else { return nil }

        switch appRequest(in: lower) {
        case .found(let app):
            let result = await MainActor.run { AgentWindows.openApp(name: app) }
            if let error = result["error"] as? String { return "Couldn't open \(app): \(error)" }
            return "Opened \(app)."
        case .notFound(let query, let suggestions):
            // Answer at once rather than spending model calls (and rate limit) on a missing app.
            guard !suggestions.isEmpty else { return "I couldn't find an app called “\(query)”." }
            return "I couldn't find an app called “\(query)”. Did you mean \(listPhrase(suggestions))?"
        case .none:
            break
        }

        if ["what time is it", "what's the time", "whats the time", "current time", "time now"].contains(
            where: lower.hasSuffix)
        {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return "It's \(formatter.string(from: Date()))."
        }

        return nil
    }

    private static let openVerbs = [
        "can you open", "could you open", "please open", "open up", "open", "launch", "start", "switch to", "go to",
    ]
    /// Only these verbs are sure enough about "it's an app" to answer "not found" themselves.
    private static let appOnlyVerbs: Set<String> = [
        "can you open", "could you open", "please open", "open up", "open", "launch",
    ]
    private static let stopWords: Set<String> = ["the", "app", "application", "please", "for", "me", "up"]
    /// Things people open that are not apps; these always go to the model.
    private static let nonAppWords: Set<String> = [
        "file", "files", "folder", "pdf", "document", "doc", "docs", "link", "page", "tab", "email", "message",
        "it", "this", "that", "downloads", "desktop", "documents", "website", "site", "settings", "window", "chat",
        "invoice", "report", "spreadsheet", "presentation", "photo", "image", "video", "note", "notes",
    ]

    enum AppRequest: Equatable {
        case found(String)
        case notFound(query: String, suggestions: [String])
    }

    /// "open slack" → found; "open crew" with no such app → notFound with close names.
    /// Only short app-like targets are claimed, so "open the Q3 report in Numbers" still
    /// reaches the model.
    static func appRequest(in lower: String, installed: [String]? = nil) -> AppRequest? {
        for verb in openVerbs where lower.hasPrefix(verb + " ") {
            let words = lower.dropFirst(verb.count + 1)
                .split(separator: " ")
                .filter { !stopWords.contains(String($0)) }
            let rest = words.joined(separator: " ")
            guard !rest.isEmpty, words.count <= 3, !rest.contains("http"), !rest.contains(".") else { return nil }
            let names = installed ?? installedAppNames()
            if let match = bestMatch(for: rest, in: names) { return .found(match) }
            guard appOnlyVerbs.contains(verb), words.count == 1, !nonAppWords.contains(rest) else { return nil }
            return .notFound(query: rest, suggestions: suggestions(for: rest, in: names))
        }
        return nil
    }

    static func bestMatch(for query: String, in names: [String]) -> String? {
        let q = query.lowercased()
        if let exact = names.first(where: { $0.lowercased() == q }) { return exact }
        if let prefix = names.filter({ $0.lowercased().hasPrefix(q) }).min(by: { $0.count < $1.count }) {
            return prefix
        }
        // "chrome" → "Google Chrome"
        if let word = names.first(where: { $0.lowercased().split(separator: " ").contains(Substring(q)) }) {
            return word
        }
        // One slip of the ear on a longer name: "slak" → "Slack".
        if q.count >= 4, let near = names.first(where: { editDistance($0.lowercased(), q) <= 1 }) { return near }
        return nil
    }

    /// Up to three installed apps that sound closest, same first letter preferred.
    static func suggestions(for query: String, in names: [String]) -> [String] {
        let q = query.lowercased()
        let scored = names.map { name -> (String, Int) in
            let candidates = [name.lowercased()] + name.lowercased().split(separator: " ").map(String.init)
            let distance = candidates.map { editDistance($0, q) }.min() ?? Int.max
            let firstLetterBonus = name.lowercased().split(separator: " ").contains { $0.first == q.first } ? 0 : 2
            return (name, distance + firstLetterBonus)
        }
        let limit = max(3, q.count / 2 + 2)
        return scored.filter { $0.1 <= limit }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }.prefix(3).map(\.0)
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    private static func listPhrase(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) or \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " or " + items.last!
        }
    }

    static func installedAppNames() -> [String] {
        let dirs = [
            "/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
        ]
        var names: [String] = []
        for dir in dirs {
            if let items = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                names += items.filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
            }
        }
        return Array(Set(names)).sorted()
    }
}
