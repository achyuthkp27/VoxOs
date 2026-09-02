import AppKit
import Foundation

/// Self-extension without recompiling. Drop a JSON manifest in
/// ~/Library/Application Support/com.achyuthkp.VoxOS/plugins/ and it becomes a tool the
/// agent can call. The action is a shell command, AppleScript, or URL template with {{arg}}
/// substitution; tool names are prefixed `plugin_` so they never collide with built-ins.
/// The agent can also write manifests itself via `plugin_create`.
///
/// Manifest:
/// {
///   "name": "open ticket",
///   "description": "Open a Jira ticket by key in the browser",
///   "parameters": { "key": "the ticket key, e.g. VOX-12" },
///   "run": { "type": "open_url", "template": "https://co.atlassian.net/browse/{{key}}" }
/// }
/// Ported and adapted from cursor-voice (MIT) PluginManager.
enum AgentPlugins {

    struct Tool {
        let name: String
        let description: String
        /// argument name → description
        let parameters: [String: String]
        let runType: String
        let template: String
        let file: URL
    }

    static let runTypes: Set<String> = ["shell", "applescript", "open_url"]

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.achyuthkp.VoxOS/plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func isPlugin(_ name: String) -> Bool { name.hasPrefix("plugin_") }

    static func sanitize(_ rawName: String) -> String {
        rawName.lowercased().replacingOccurrences(of: " ", with: "_").filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    static func load() -> [Tool] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var tools: [Tool] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let rawName = object["name"] as? String,
                let description = object["description"] as? String,
                let run = object["run"] as? [String: Any],
                let runType = run["type"] as? String, runTypes.contains(runType),
                let template = run["template"] as? String
            else { continue }
            let sanitized = sanitize(rawName)
            guard !sanitized.isEmpty else { continue }

            // Accept either the simple {arg: description} form or a JSON-schema "properties" block.
            var parameters: [String: String] = [:]
            if let simple = object["parameters"] as? [String: String] {
                parameters = simple
            } else if let schema = object["parameters"] as? [String: Any],
                let properties = schema["properties"] as? [String: Any]
            {
                for (key, value) in properties {
                    parameters[key] = ((value as? [String: Any])?["description"] as? String) ?? "string"
                }
            }
            tools.append(Tool(name: "plugin_\(sanitized)", description: description, parameters: parameters, runType: runType, template: template, file: file))
        }
        return tools.sorted { $0.name < $1.name }
    }

    /// One line per plugin, in the same shape the built-in tool list uses in the prompt.
    static func promptLines() -> [String] {
        load().map { tool in
            let args = tool.parameters.keys.sorted().map { "\"\($0)\": str" }.joined(separator: ", ")
            return "- \(tool.name) {\(args)} -> \(tool.description)"
        }
    }

    static func run(name: String, args: [String: Any]) async -> [String: Any] {
        guard let tool = load().first(where: { $0.name == name }) else { return ["error": "unknown plugin tool \(name)"] }
        let command = substitute(tool.template, args: args, runType: tool.runType)
        switch tool.runType {
        case "open_url":
            guard let url = URL(string: command), url.scheme != nil else { return ["error": "invalid URL: \(command)"] }
            await MainActor.run { _ = NSWorkspace.shared.open(url) }
            return ["ok": true, "opened": command]
        case "applescript":
            return await MainActor.run { AgentAppleScript.run(command) }
        case "shell":
            return await AgentShell.run(command)
        default:
            return ["error": "unsupported run type \(tool.runType)"]
        }
    }

    /// Lets the agent extend itself: write a manifest from a spoken description.
    static func create(name: String, description: String, runType: String, template: String, parameters: [String: String]) -> [String: Any] {
        let sanitized = sanitize(name)
        guard !sanitized.isEmpty else { return ["error": "name is required"] }
        guard runTypes.contains(runType) else { return ["error": "run_type must be one of shell, applescript, open_url"] }
        guard !template.isEmpty else { return ["error": "template is required"] }
        if runType == "shell", let risk = AgentShell.riskReason(template) {
            return ["error": "refusing to save a plugin whose command looks risky (\(risk))"]
        }
        let manifest: [String: Any] = [
            "name": name, "description": description, "parameters": parameters,
            "run": ["type": runType, "template": template],
        ]
        let file = directory.appendingPathComponent("\(sanitized).json")
        do {
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: file, options: .atomic)
        } catch {
            return ["error": "could not save plugin: \(error.localizedDescription)"]
        }
        return ["ok": true, "tool": "plugin_\(sanitized)", "file": file.path, "note": "Saved. It is callable from the next request onward."]
    }

    static func delete(name: String) -> [String: Any] {
        let wanted = name.hasPrefix("plugin_") ? name : "plugin_\(sanitize(name))"
        guard let tool = load().first(where: { $0.name == wanted }) else { return ["error": "no plugin named \(name)"] }
        try? FileManager.default.removeItem(at: tool.file)
        return ["ok": true, "deleted": tool.name]
    }

    private static func substitute(_ template: String, args: [String: Any], runType: String) -> String {
        var s = template
        for (key, value) in args {
            let raw = "\(value)"
            let safe: String
            switch runType {
            case "shell": safe = "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
            case "open_url": safe = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
            case "applescript": safe = raw.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            default: safe = raw
            }
            s = s.replacingOccurrences(of: "{{\(key)}}", with: safe)
        }
        return s
    }
}
