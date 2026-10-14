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

        AgentAutoClose.beginRun()
        setPendingSuggestions([])
        switch appRequest(in: lower) {
        case .found(let app):
            if let blocked = blockedOpenReply(app) { return blocked }
            let result = await MainActor.run { AgentWindows.openApp(name: app) }
            if let error = result["error"] as? String { return "Couldn't open \(app): \(error)" }
            AgentAutoClose.recordQuickLaunch()
            return "Opened \(app)."
        case .notFound(let query, let suggestions):
            // Answer at once rather than spending model calls (and rate limit) on a missing app.
            guard !suggestions.isEmpty else { return "I couldn't find an app called “\(query)”." }
            setPendingSuggestions(suggestions)
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

    /// Words that point back at something already said; they never name an app.
    private static let pronouns: Set<String> = ["it", "this", "that", "them", "these", "those"]

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
            // Checked before any loose match: "open it" in a follow-up means the thing just talked
            // about, and a prefix match turned it into iTerm. A pronoun is never an app. A common
            // noun such as "notes" or "settings" only counts when it is an app's whole name or one
            // whole word of it, so "open notes" still opens Notes.
            if words.count == 1, pronouns.contains(rest) { return nil }
            if words.count == 1, nonAppWords.contains(rest) {
                return wholeNameMatch(for: rest, in: names).map(AppRequest.found)
            }
            if let match = bestMatch(for: rest, in: names) { return .found(match) }
            guard appOnlyVerbs.contains(verb), words.count == 1, !nonAppWords.contains(rest) else { return nil }
            return .notFound(query: rest, suggestions: suggestions(for: rest, in: names))
        }
        return nil
    }

    /// An app whose whole name is the query, or which has the query as one whole word of its
    /// name. No prefixes and no misspellings.
    private static func wholeNameMatch(for query: String, in names: [String]) -> String? {
        let q = query.lowercased()
        if let exact = names.first(where: { $0.lowercased() == q }) { return exact }
        return names.first(where: { $0.lowercased().split(separator: " ").contains(Substring(q)) })
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

    /// Up to three installed apps that sound close to what was said. Close means a slip of the ear,
    /// not just a shared letter: a short name tolerates one wrong letter, a longer one two or three.
    /// Offering "Stocks" for "slack" is worse than offering nothing, because the user then says "yes".
    static func suggestions(for query: String, in names: [String]) -> [String] {
        let q = query.lowercased()
        let scored = names.map { name -> (String, Int) in
            let candidates = [name.lowercased()] + name.lowercased().split(separator: " ").map(String.init)
            let distance = candidates.map { editDistance($0, q) }.min() ?? Int.max
            let firstLetterPenalty = name.lowercased().split(separator: " ").contains { $0.first == q.first } ? 0 : 1
            return (name, distance + firstLetterPenalty)
        }
        let limit = q.count <= 4 ? 1 : (q.count <= 8 ? 2 : 3)
        return scored.filter { $0.1 <= limit }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }.prefix(3).map(\.0)
    }

    // MARK: Answering "yes" to "Did you mean …?"

    private static let pendingLock = NSLock()
    private static var pendingSuggestions: [String] = []

    static func setPendingSuggestions(_ names: [String]) {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        pendingSuggestions = names
    }

    /// What the last not-found reply offered. Taking it forgets it, so a "yes" two questions later
    /// can never open an app the user has long since stopped talking about.
    static func takePendingSuggestions() -> [String] {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        defer { pendingSuggestions = [] }
        return pendingSuggestions
    }

    enum FollowUp: Equatable {
        case open(String)
        case ask(question: String, suggestions: [String])
    }

    private static let affirmatives: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "correct", "right", "please", "do it", "go ahead",
        "yes please", "yeah sure", "sure thing", "that one",
    ]

    /// A short reply to a "Did you mean …?" that can be answered without a model: "yes" for a single
    /// offer, or naming one of the offers. "yes" to several is ambiguous, so it asks which.
    /// Anything else (a question, "no", a new request) goes on to the model as usual.
    static func followUp(reply: String, suggestions: [String]) -> FollowUp? {
        guard !suggestions.isEmpty else { return nil }
        let cleaned = reply.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !cleaned.isEmpty, cleaned.split(separator: " ").count <= 4 else { return nil }

        if let named = suggestions.first(where: {
            let name = $0.lowercased()
            return cleaned == name || cleaned == "open \(name)" || cleaned == "the \(name)"
        }) {
            return .open(named)
        }
        guard affirmatives.contains(cleaned) else { return nil }
        if suggestions.count == 1 { return .open(suggestions[0]) }
        return .ask(question: "Which one: \(listPhrase(suggestions))?", suggestions: suggestions)
    }

    /// The offer made by the last "Did you mean …?", applied to this reply. Taking it forgets it.
    static func takeFollowUp(reply: String) -> FollowUp? {
        followUp(reply: reply, suggestions: takePendingSuggestions())
    }

    /// Answers a follow-up locally when it can, or returns nil for the model to answer.
    ///
    /// The pending offer is resolved first. `handle` starts a new request and forgets the offer,
    /// so running it first turned every "yes" into a question for a model that never saw the
    /// offer. Only a reply that does not answer the offer runs as a fresh quick intent, which is
    /// what keeps "open Chrome" typed as a follow-up opening Chrome.
    static func answerFollowUp(_ reply: String) async -> String? {
        if let local = takeFollowUp(reply: reply) {
            AgentAutoClose.beginRun()
            return await perform(local)
        }
        return await handle(reply)
    }

    /// Carries out a local follow-up and returns the reply to show.
    static func perform(_ followUp: FollowUp) async -> String {
        switch followUp {
        case .open(let app):
            if let blocked = blockedOpenReply(app) { return blocked }
            let result = await MainActor.run { AgentWindows.openApp(name: app) }
            if let error = result["error"] as? String { return "Couldn't open \(app): \(error)" }
            AgentAutoClose.recordQuickLaunch()
            return "Opened \(app)."
        case .ask(let question, let suggestions):
            setPendingSuggestions(suggestions)
            return question
        }
    }

    /// A quick launch is the open_app tool without the model, so it obeys the same control
    /// mode (the app's own, else the global): observe-only refuses, ask-before-acting holds it
    /// for "confirm". Returns the reply to show when the app may not open right now.
    static func blockedOpenReply(_ app: String) -> String? {
        let args: [String: Any] = ["name": app]
        switch AgentControlMode.mode(forTool: "open_app", args: args) {
        case .takeover:
            return nil
        case .observeOnly:
            return "The Agent is set to observe only, so I won't open \(app)."
        case .askBeforeAction:
            AgentPendingAction.set(name: "open_app", args: args)
            return "Ready to open \(app). Say “confirm” or “cancel”."
        }
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
