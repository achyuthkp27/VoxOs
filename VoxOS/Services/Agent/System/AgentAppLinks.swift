import AppKit
import Foundation

/// Deep links into apps that have no API worth wiring: Obsidian, VS Code, Cursor, Apple Maps,
/// Telegram. Pure URL builders (unit-tested) plus a thin opener that reports when the app is
/// not installed instead of silently doing nothing.
enum AgentAppLinks {

    // MARK: - Builders

    static func obsidianURL(vault: String, name: String, content: String, append: Bool) -> URL? {
        var items: [URLQueryItem] = []
        if !vault.isEmpty { items.append(URLQueryItem(name: "vault", value: vault)) }
        items.append(URLQueryItem(name: "name", value: name.isEmpty ? "Untitled" : name))
        if !content.isEmpty { items.append(URLQueryItem(name: "content", value: content)) }
        if append { items.append(URLQueryItem(name: "append", value: "true")) }
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "new"
        components.queryItems = items
        return components.url
    }

    /// `vscode://file/<path>[:line]` — Cursor uses the same shape with its own scheme.
    static func editorURL(path: String, editor: String, line: Int?) -> URL? {
        let scheme: String
        switch editor.lowercased() {
        case "cursor": scheme = "cursor"
        case "vscode", "code", "vs code", "visual studio code", "": scheme = "vscode"
        default: return nil
        }
        let expanded = (path as NSString).expandingTildeInPath
        var components = URLComponents()
        components.scheme = scheme
        components.host = "file"
        components.path = expanded + (line.map { ":\($0)" } ?? "")
        return components.url
    }

    static func mapsSearchURL(query: String) -> URL? {
        var components = URLComponents()
        components.scheme = "maps"
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url
    }

    static func mapsDirectionsURL(to destination: String, from origin: String, mode: String) -> URL? {
        var items = [URLQueryItem(name: "daddr", value: destination)]
        if !origin.isEmpty { items.append(URLQueryItem(name: "saddr", value: origin)) }
        let flag: String
        switch mode.lowercased() {
        case "walk", "walking": flag = "w"
        case "transit", "public transport", "train", "bus": flag = "r"
        default: flag = "d"
        }
        items.append(URLQueryItem(name: "dirflg", value: flag))
        var components = URLComponents()
        components.scheme = "maps"
        components.queryItems = items
        return components.url
    }

    /// `tg://msg?text=…&to=…` opens Telegram with the message prefilled; the user presses Send.
    static func telegramURL(to recipient: String, text: String) -> URL? {
        var items = [URLQueryItem(name: "text", value: text)]
        if !recipient.isEmpty { items.append(URLQueryItem(name: "to", value: recipient)) }
        var components = URLComponents()
        components.scheme = "tg"
        components.host = "msg"
        components.queryItems = items
        return components.url
    }

    // MARK: - Opening

    @MainActor
    static func open(_ url: URL?, appName: String, success: String) -> [String: Any] {
        guard let url else { return ["error": "could not build a \(appName) link"] }
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            return ["error": "\(appName) is not installed (nothing handles \(url.scheme ?? "") links)"]
        }
        return NSWorkspace.shared.open(url)
            ? ["result": success]
            : ["error": "\(appName) refused to open the link"]
    }
}
