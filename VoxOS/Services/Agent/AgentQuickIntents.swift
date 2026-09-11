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

        if let app = appName(in: lower) {
            let result = await MainActor.run { AgentWindows.openApp(name: app) }
            if let error = result["error"] as? String { return "Couldn't open \(app): \(error)" }
            return "Opened \(app.capitalized)."
        }

        if ["what time is it", "what's the time", "whats the time", "current time", "time now"].contains(where: lower.hasSuffix) {
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return "It's \(formatter.string(from: Date()))."
        }

        return nil
    }

    private static let openVerbs = ["can you open", "could you open", "please open", "open up", "open", "launch", "start", "switch to", "go to"]
    private static let stopWords: Set<String> = ["the", "app", "application", "please", "for", "me", "up"]

    private static func appName(in lower: String) -> String? {
        for verb in openVerbs where lower.hasPrefix(verb + " ") {
            let rest = lower.dropFirst(verb.count + 1)
                .split(separator: " ")
                .filter { !stopWords.contains(String($0)) }
                .joined(separator: " ")
            guard !rest.isEmpty, rest.count <= 30, !rest.contains("http"), !rest.contains(".") else { return nil }
            // Only claim the intent when such an app is actually installed.
            return installedAppName(matching: rest)
        }
        return nil
    }

    private static func installedAppName(matching query: String) -> String? {
        let q = query.lowercased()
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                    NSHomeDirectory() + "/Applications"]
        var names: [String] = []
        for dir in dirs {
            if let items = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                names += items.filter { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
            }
        }
        if let exact = names.first(where: { $0.lowercased() == q }) { return exact }
        if let prefix = names.first(where: { $0.lowercased().hasPrefix(q) }) { return prefix }
        // "chrome" → "Google Chrome"
        if let contains = names.first(where: { $0.lowercased().split(separator: " ").contains(where: { $0 == Substring(q) }) }) { return contains }
        return nil
    }
}
