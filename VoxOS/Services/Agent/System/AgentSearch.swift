import Foundation

/// "Find the Figma invoice": one query, every place the user keeps things. Finder via
/// Spotlight, plus every connected MCP tool that searches (Notion, Drive, Gmail servers…),
/// all in parallel with a per-source timeout so one slow server cannot stall the answer.
enum AgentSearch {

    static let sourceTimeout: TimeInterval = 15
    static let queryParameterNames = ["query", "q", "search", "search_query", "keyword", "keywords", "term", "text"]

    /// A connected MCP tool usable as a search source, and the argument that takes the query.
    struct Source {
        let tool: MCPTool
        let queryParameter: String
    }

    /// Picks MCP tools that look like searches and have a string argument for the query.
    /// Only tools named like a search or marked read-only qualify, so fanning out can never
    /// trigger a write behind the control-mode gate.
    static func sources(from tools: [MCPTool]) -> [Source] {
        tools.compactMap { tool in
            let lowered = tool.name.lowercased()
            let looksLikeSearch = lowered.contains("search") || lowered.hasPrefix("find") || lowered.contains("_find")
            guard looksLikeSearch else { return nil }
            guard tool.readOnly || lowered.contains("search") else { return nil }

            let properties = (tool.inputSchema["properties"] as? [String: Any]) ?? [:]
            let required = (tool.inputSchema["required"] as? [String]) ?? []
            let stringParameters = properties.compactMap { key, value -> String? in
                ((value as? [String: Any])?["type"] as? String) == "string" ? key : nil
            }
            // Every other required argument must be absent, or we cannot call it with a query alone.
            if let named = queryParameterNames.first(where: { stringParameters.contains($0) }),
                required.allSatisfy({ $0 == named })
            {
                return Source(tool: tool, queryParameter: named)
            }
            let requiredStrings = required.filter { stringParameters.contains($0) }
            if required.count == 1, requiredStrings.count == 1 {
                return Source(tool: tool, queryParameter: requiredStrings[0])
            }
            return nil
        }
    }

    static func run(query rawQuery: String) async -> [String: Any] {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ["error": "query is required"] }

        await AgentMCP.ensureStarted(maxWait: 3)
        let mcpSources = sources(from: AgentMCP.tools)

        async let files = spotlight(query)
        let remote = await withTaskGroup(of: MCPJSON.self) { group -> [[String: Any]] in
            for source in mcpSources {
                group.addTask {
                    let fallback = MCPJSON(value: [
                        "source": source.tool.server, "tool": source.tool.exposedName, "error": "timed out",
                    ])
                    return await mcpRace(seconds: sourceTimeout) {
                        let result = await AgentMCP.call(
                            name: source.tool.exposedName, args: [source.queryParameter: query])
                        var entry: [String: Any] = ["source": source.tool.server, "tool": source.tool.exposedName]
                        if let error = result["error"] as? String {
                            entry["error"] = error
                        } else {
                            let output = (result["output"] as? String) ?? ""
                            entry["results"] = output.count > 1500 ? String(output.prefix(1500)) + "…" : output
                        }
                        return MCPJSON(value: entry)
                    } ?? fallback
                }
            }
            var collected: [[String: Any]] = []
            for await entry in group { collected.append(entry.value) }
            return collected.sorted { ($0["source"] as? String ?? "") < ($1["source"] as? String ?? "") }
        }

        let finderMatches = await files
        var result: [String: Any] = ["query": query, "files": finderMatches]
        if !remote.isEmpty { result["sources"] = remote }
        if mcpSources.isEmpty {
            result["note"] =
                "Only Finder was searched. Connect MCP servers (Settings → Agent → MCP Servers) to also search Notion, Drive, Gmail and more."
        }
        return result
    }

    /// Spotlight file-name search under the home folder. Arguments are passed directly, never
    /// through a shell, so the query cannot inject anything.
    static func spotlight(_ query: String, limit: Int = 15) async -> [String] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
                process.arguments = ["-onlyin", NSHomeDirectory(), "-name", query]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: [])
                    return
                }
                let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: watchdog)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                let paths = String(decoding: data, as: UTF8.self)
                    .split(whereSeparator: \.isNewline)
                    .map(String.init)
                    .filter { !$0.contains("/Library/") && !$0.contains("/.") }
                continuation.resume(returning: Array(paths.prefix(limit)))
            }
        }
    }
}
