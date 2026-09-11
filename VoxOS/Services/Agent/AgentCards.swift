import Foundation

/// Structured results worth showing as a card under the agent's reply instead of prose:
/// files it found, links it searched up, a screenshot it took.
enum AgentCard: Equatable, Identifiable {
    case files([String])
    case links([Link])
    case image(path: String)

    struct Link: Equatable, Identifiable {
        let title: String
        let url: String
        var id: String { url }
    }

    var id: String {
        switch self {
        case .files(let paths): return "files:" + paths.joined(separator: "|")
        case .links(let links): return "links:" + links.map(\.url).joined(separator: "|")
        case .image(let path): return "image:" + path
        }
    }

    /// Builds a card from a tool's result dictionary, when the tool is one we render.
    static func from(tool: String, result: [String: Any]) -> AgentCard? {
        guard result["error"] == nil else { return nil }
        switch tool {
        case "find_files":
            let matches = (result["matches"] as? [String]) ?? []
            return matches.isEmpty ? nil : .files(Array(matches.prefix(8)))
        case "web_results":
            let raw = (result["results"] as? [[String: Any]]) ?? []
            let links = raw.compactMap { item -> Link? in
                guard let url = item["url"] as? String, !url.isEmpty else { return nil }
                return Link(title: (item["title"] as? String) ?? url, url: url)
            }
            return links.isEmpty ? nil : .links(Array(links.prefix(5)))
        case "take_screenshot":
            guard let path = result["path"] as? String else { return nil }
            return .image(path: path)
        default:
            return nil
        }
    }
}

/// Cards produced during the current agent run, drained into the reply message when it lands.
enum AgentCardStore {
    private static let lock = NSLock()
    private static var pending: [AgentCard] = []

    static func add(_ card: AgentCard) {
        lock.lock(); defer { lock.unlock() }
        if !pending.contains(card) { pending.append(card) }
    }

    static func drain() -> [AgentCard] {
        lock.lock(); defer { lock.unlock() }
        let cards = pending
        pending = []
        return cards
    }

    static func clear() {
        lock.lock(); defer { lock.unlock() }
        pending = []
    }
}
