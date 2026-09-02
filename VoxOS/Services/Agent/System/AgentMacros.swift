import Foundation

/// Macros — "teach it a skill". While recording, every tool call the agent performs is
/// captured; replaying runs the same steps again. Stored as JSON next to VoxOS's data.
/// Ported from cursor-voice (MIT) MacroStore.
enum AgentMacros {

    struct Step: Codable {
        let tool: String
        /// JSON so arrays and dictionaries (hotkey keys, batch steps) replay intact.
        let argsJSON: String

        var args: [String: Any] {
            guard let data = argsJSON.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return [:] }
            return object
        }
    }

    struct Macro: Codable {
        var name: String
        var steps: [Step]
        var createdAt: Date
    }

    private static let lock = NSLock()
    private static var recording: Macro?

    // MARK: - Recording

    static var isRecording: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recording != nil
    }

    static var recordingName: String? {
        lock.lock()
        defer { lock.unlock() }
        return recording?.name
    }

    static func startRecording(name: String) -> [String: Any] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return ["error": "macro needs a name"] }
        lock.lock()
        recording = Macro(name: trimmed, steps: [], createdAt: Date())
        lock.unlock()
        return [
            "ok": true, "recording": trimmed,
            "note": "Recording started. Every action from now on is captured until macro_record_stop is called. Tell the user to do the steps by voice, then say 'stop recording'.",
        ]
    }

    static func stopRecording() -> [String: Any] {
        lock.lock()
        let macro = recording
        recording = nil
        lock.unlock()
        guard let macro else { return ["error": "not recording a macro"] }
        guard !macro.steps.isEmpty else { return ["ok": false, "note": "No actions were recorded, so nothing was saved."] }
        save(macro)
        return ["ok": true, "saved": macro.name, "steps": macro.steps.count, "note": "Saved. Replay it with macro_run."]
    }

    /// Called by the dispatcher after every successful mutating tool call.
    static func record(tool: String, args: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        guard recording != nil else { return }
        guard JSONSerialization.isValidJSONObject(args),
            let data = try? JSONSerialization.data(withJSONObject: args),
            let json = String(data: data, encoding: .utf8)
        else { return }
        recording?.steps.append(Step(tool: tool, argsJSON: json))
    }

    // MARK: - Storage

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.achyuthkp.VoxOS/macros", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    static func slug(_ name: String) -> String {
        let s = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: #"\s+"#, with: "-", options: .regularExpression)
            .filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
            .replacingOccurrences(of: #"-{2,}"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s.isEmpty ? "macro" : s
    }

    private static func url(for name: String) -> URL { directory.appendingPathComponent("\(slug(name)).json") }

    static func save(_ macro: Macro) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(macro) { try? data.write(to: url(for: macro.name), options: .atomic) }
    }

    /// Exact slug, or a single unambiguous prefix match of at least three characters.
    static func load(_ name: String) -> Macro? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url(for: name)), let macro = try? decoder.decode(Macro.self, from: data) {
            return macro
        }
        let want = slug(name)
        guard want.count >= 3 else { return nil }
        let candidates = list().filter { slug($0.name).hasPrefix(want) }
        return candidates.count == 1 ? candidates.first : nil
    }

    /// Deletion never guesses.
    static func loadExact(_ name: String) -> Macro? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url(for: name)) else { return nil }
        return try? decoder.decode(Macro.self, from: data)
    }

    static func list() -> [Macro] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Macro.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name < $1.name }
    }

    @discardableResult
    static func delete(_ name: String) -> Bool {
        guard let macro = loadExact(name) else { return false }
        try? FileManager.default.removeItem(at: url(for: macro.name))
        return true
    }
}
