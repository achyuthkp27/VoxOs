import Foundation
import Testing

@testable import VoxOS

/// MCP client: config parsing, tool naming, prompt rendering, result flattening, search source
/// selection, and a real stdio round trip against a tiny fake server.
@Suite(.serialized)
struct AgentMCPTests {

    // MARK: Config

    @Test func parsesStandardConfig() {
        let json = """
            {"mcpServers": {
              "notion": {"command": "npx", "args": ["-y", "@notionhq/notion-mcp-server"], "env": {"NOTION_TOKEN": "x", "PORT": 3}},
              "remote": {"url": "https://mcp.example.com/sse"},
              "off": {"command": "uvx", "args": ["thing"], "disabled": true}
            }}
            """
        let configs = AgentMCP.parseConfig(Data(json.utf8))
        #expect(configs.map(\.name) == ["notion", "off", "remote"])

        let notion = configs[0]
        #expect(notion.command == "npx")
        #expect(notion.args == ["-y", "@notionhq/notion-mcp-server"])
        #expect(notion.env["NOTION_TOKEN"] == "x")
        #expect(notion.env["PORT"] == "3", "non-string env values are stringified")
        #expect(notion.isSupported)

        #expect(configs[1].disabled)
        #expect(configs[2].remoteURL == "https://mcp.example.com/sse")
        #expect(configs[2].isSupported, "http(s) remote servers are started over Streamable HTTP")
        #expect(configs[2].isRemote)

        #expect(AgentMCP.parseConfig(Data("not json".utf8)).isEmpty)
    }

    // MARK: Naming

    @Test func exposedNamesAreSanitizedAndUnique() {
        let names = AgentMCP.exposedNames(for: [
            (server: "Google Drive", tool: "search-files"),
            (server: "google_drive", tool: "search files"),
            (server: "notion", tool: "API-post-search"),
        ])
        #expect(
            names == ["mcp_google_drive_search_files", "mcp_google_drive_search_files_2", "mcp_notion_api_post_search"])
    }

    // MARK: Prompt

    @Test func promptLineShowsTypesRequiredAndAccess() {
        let tool = MCPTool(
            server: "notion", name: "search", exposedName: "mcp_notion_search",
            description: "Search pages and databases.\nLong second line that must not appear.",
            inputSchema: [
                "type": "object",
                "properties": [
                    "query": ["type": "string"],
                    "limit": ["type": "integer"],
                    "sort": ["type": "string", "enum": ["asc", "desc"]],
                    "tags": ["type": "array", "items": ["type": "string"]],
                ],
                "required": ["query"],
            ],
            readOnly: true)
        let line = AgentMCP.promptLine(for: tool)
        #expect(
            line
                == #"- mcp_notion_search {"limit": int?, "query": str, "sort": "asc"|"desc"?, "tags": [str]?} -> Search pages and databases. (notion) [read-only]"#
        )
    }

    // MARK: Results

    @Test func rendersCallResults() {
        let ok = AgentMCP.render(result: [
            "content": [
                ["type": "text", "text": "first"],
                ["type": "image", "mimeType": "image/png", "data": "…"],
                ["type": "resource_link", "name": "Q3", "uri": "https://x/q3"],
            ]
        ])
        #expect(ok["output"] as? String == "first\n[image image/png]\n[link Q3 https://x/q3]")

        let failed = AgentMCP.render(result: ["content": [["type": "text", "text": "no access"]], "isError": true])
        #expect(failed["error"] as? String == "no access")

        let structured = AgentMCP.render(result: ["content": [], "structuredContent": ["count": 2]])
        #expect(structured["output"] as? String == #"{"count":2}"#)

        let long = AgentMCP.render(
            result: ["content": [["type": "text", "text": String(repeating: "a", count: 50)]]], limit: 10)
        #expect((long["output"] as? String)?.hasSuffix("…(truncated)") == true)
    }

    // MARK: Search sources

    @Test func searchSourcesOnlyPickCallableSearches() {
        func tool(_ name: String, _ schema: [String: Any], readOnly: Bool = false) -> MCPTool {
            MCPTool(
                server: "s", name: name, exposedName: "mcp_s_\(name)", description: "", inputSchema: schema,
                readOnly: readOnly)
        }
        let picked = AgentSearch.sources(from: [
            tool("search", ["properties": ["query": ["type": "string"]], "required": ["query"]]),
            tool("search_files", ["properties": ["pattern": ["type": "string"]], "required": ["pattern"]]),
            tool(
                "search_in_folder",
                [
                    "properties": ["query": ["type": "string"], "folder": ["type": "string"]],
                    "required": ["query", "folder"],
                ]),
            tool("find_page", ["properties": ["q": ["type": "string"]]], readOnly: false),
            tool("create_page", ["properties": ["title": ["type": "string"]], "required": ["title"]]),
            // Named like a search, but it writes: must never be fanned out to.
            tool("search_and_archive", ["properties": ["query": ["type": "string"]], "required": ["query"]]),
        ])
        #expect(picked.map(\.tool.name) == ["search", "search_files"])
        #expect(picked.map(\.queryParameter) == ["query", "pattern"])
    }

    // MARK: Round trip

    private static let python = "/usr/bin/python3"

    private static let fakeServer = #"""
        import sys, json
        def send(o):
            sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
        print("starting fake server", file=sys.stderr)
        for line in sys.stdin:
            m = json.loads(line)
            mid, meth = m.get("id"), m.get("method")
            if meth == "initialize":
                send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1"}}})
            elif meth == "notifications/initialized":
                send({"jsonrpc": "2.0", "id": "srv-ping", "method": "ping"})
            elif meth == "tools/list":
                if not (m.get("params") or {}).get("cursor"):
                    send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [{"name": "echo", "description": "Echo text", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}, "annotations": {"readOnlyHint": True}}], "nextCursor": "page2"}})
                else:
                    send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [{"name": "boom", "description": "Always fails", "inputSchema": {"type": "object", "properties": {}}}]}})
            elif meth == "tools/call":
                name = m["params"]["name"]; args = m["params"].get("arguments", {})
                if name == "echo":
                    send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": "echo: " + args.get("text", "")}]}})
                elif name == "exit":
                    sys.exit(3)
                else:
                    send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": "kaboom"}], "isError": True}})
            elif meth is not None and mid is not None:
                send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "nope"}})
        """#

    private func makeServer() throws -> MCPConnection {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent(
            "voxos-fake-mcp-\(UUID().uuidString).py")
        try Self.fakeServer.write(to: script, atomically: true, encoding: .utf8)
        return MCPConnection(
            config: MCPServerConfig(
                name: "fake", command: Self.python, args: ["-u", script.path], env: [:], disabled: false, remoteURL: nil
            ))
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func stdioRoundTrip() async throws {
        let connection = try makeServer()
        defer { connection.stop() }

        try await connection.start(path: ShellPath.fallback)
        #expect(connection.state == .ready)

        let tools = connection.rawTools
        #expect(tools.map(\.name) == ["echo", "boom"], "both pages of tools/list are collected")
        #expect(tools.first?.readOnly == true)
        #expect(tools.last?.readOnly == false)

        let echoed = AgentMCP.render(
            result: try await connection.callTool(name: "echo", arguments: ["text": "hi \"there\"\nnext"]))
        #expect(echoed["output"] as? String == "echo: hi \"there\"\nnext")

        let failed = AgentMCP.render(result: try await connection.callTool(name: "boom", arguments: [:]))
        #expect(failed["error"] as? String == "kaboom")

        await #expect(throws: MCPError.self) {
            _ = try await connection.request("unknown/method", params: nil, timeout: 5)
        }
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func serverExitFailsPendingRequestsQuickly() async throws {
        let connection = try makeServer()
        defer { connection.stop() }
        try await connection.start(path: ShellPath.fallback)

        let started = Date()
        await #expect(throws: MCPError.self) {
            _ = try await connection.callTool(name: "exit", arguments: [:], timeout: 30)
        }
        #expect(Date().timeIntervalSince(started) < 5, "a dead server must not wait for the call timeout")
        if case .failed = connection.state {
        } else {
            Issue.record("state should be failed after the server exits, got \(connection.state)")
        }
    }

    @Test func missingCommandFailsWithoutLaunching() async {
        let connection = MCPConnection(
            config: MCPServerConfig(
                name: "ghost", command: "definitely-not-a-real-mcp-binary", args: [], env: [:], disabled: false,
                remoteURL: nil))
        await #expect(throws: MCPError.self) {
            try await connection.start(path: "/usr/bin:/bin")
        }
        if case .failed(let reason) = connection.state {
            #expect(reason.contains("command not found"))
        } else {
            Issue.record("expected failed state")
        }
    }

    @Test func raceReturnsWithoutWaitingForSlowWork() async {
        let started = Date()
        let value: Int? = await mcpRace(seconds: 0.2) {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return 1
        }
        #expect(value == nil)
        #expect(Date().timeIntervalSince(started) < 1)

        let fast: Int? = await mcpRace(seconds: 2) { 7 }
        #expect(fast == 7)
    }

    /// Real server, real npm download. Opt-in: `TEST_RUNNER_VOXOS_LIVE_MCP=1 make test`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VOXOS_LIVE_MCP"] == "1"))
    func liveFilesystemServer() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "voxos-live-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "hello from voxos".write(to: folder.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        let root = folder.resolvingSymlinksInPath().path

        let connection = MCPConnection(
            config: MCPServerConfig(
                name: "filesystem", command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", root],
                env: [:], disabled: false, remoteURL: nil))
        defer { connection.stop() }

        try await connection.start(path: await ShellPath.value())
        let names = connection.rawTools.map(\.name)
        #expect(names.contains("read_text_file") || names.contains("read_file"))

        let tool = names.contains("read_text_file") ? "read_text_file" : "read_file"
        let read = AgentMCP.render(
            result: try await connection.callTool(name: tool, arguments: ["path": root + "/note.txt"]))
        #expect((read["output"] as? String)?.contains("hello from voxos") == true, "got \(read)")
    }

    // MARK: Streamable HTTP

    private static let fakeHTTPServer = #"""
        import json, sys, threading
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        state = {"sessions": {"sess-1"}, "next": 1, "inits": 0}
        class H(BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def send_json(self, code, obj, headers=None):
                body = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                for k, v in (headers or {}).items(): self.send_header(k, v)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers(); self.wfile.write(body)
            def do_DELETE(self):
                self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers()
            def do_POST(self):
                if self.headers.get("Authorization") != "Bearer tok-123":
                    self.send_response(401); self.send_header("Content-Length", "0"); self.end_headers(); return
                msg = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                meth, mid = msg.get("method"), msg.get("id")
                if meth == "initialize":
                    state["inits"] += 1
                    sid = "sess-%d" % state["inits"]
                    state["sessions"].add(sid)
                    self.send_json(200, {"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}}}, {"Mcp-Session-Id": sid})
                    return
                if self.headers.get("Mcp-Session-Id") not in state["sessions"]:
                    self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers(); return
                if mid is None:
                    self.send_response(202); self.send_header("Content-Length", "0"); self.end_headers(); return
                if meth == "tools/list":
                    events = [
                        {"jsonrpc": "2.0", "id": "srv-ping", "method": "ping"},
                        {"jsonrpc": "2.0", "id": mid, "result": {"tools": [
                            {"name": "echo", "description": "Echo", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}, "annotations": {"readOnlyHint": True}},
                            {"name": "forget", "description": "Drop sessions", "inputSchema": {"type": "object"}}]}},
                    ]
                    body = "".join("event: message\ndata: %s\n\n" % json.dumps(e) for e in events).encode()
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers(); self.wfile.write(body); return
                if meth == "tools/call":
                    name = msg["params"]["name"]
                    if name == "forget":
                        state["sessions"].clear()
                        self.send_json(200, {"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": "forgotten"}]}}); return
                    text = msg["params"].get("arguments", {}).get("text", "")
                    self.send_json(200, {"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": "http echo: " + text}]}}); return
                if mid is not None and meth is None:
                    self.send_response(202); self.send_header("Content-Length", "0"); self.end_headers(); return
                self.send_json(200, {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "nope"}})
        server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        print(server.server_address[1], flush=True)
        server.serve_forever()
        """#

    private func launchHTTPServer() throws -> (Process, Int) {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent(
            "voxos-fake-http-mcp-\(UUID().uuidString).py")
        try Self.fakeHTTPServer.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.python)
        process.arguments = ["-u", script.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        var line = Data()
        while true {
            let byte = pipe.fileHandleForReading.readData(ofLength: 1)
            if byte.isEmpty || byte == Data([0x0A]) { break }
            line.append(byte)
        }
        guard let port = Int(String(decoding: line, as: UTF8.self)) else {
            process.terminate()
            throw MCPError.badMessage
        }
        return (process, port)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/python3")))
    func streamableHTTPRoundTrip() async throws {
        let (server, port) = try launchHTTPServer()
        defer { server.terminate() }

        let unauthorised = MCPHTTPConnection(
            config: MCPServerConfig(
                name: "remote", command: "", args: [], env: [:], disabled: false,
                remoteURL: "http://127.0.0.1:\(port)/mcp"))
        await #expect(throws: MCPError.self) { try await unauthorised.start(path: "") }
        if case .failed(let reason) = unauthorised.state {
            #expect(reason.contains("not authorised"))
        } else {
            Issue.record("a 401 should fail the connection with an auth hint")
        }

        let connection = MCPHTTPConnection(
            config: MCPServerConfig(
                name: "remote", command: "", args: [], env: [:], disabled: false,
                remoteURL: "http://127.0.0.1:\(port)/mcp",
                headers: ["Authorization": "Bearer ${VOXOS_TEST_TOKEN_UNSET}tok-123"]))
        defer { connection.stop() }

        try await connection.start(path: "")
        #expect(connection.state == .ready)
        #expect(connection.rawTools.map(\.name) == ["echo", "forget"], "tools arrive over SSE after a server ping")
        #expect(connection.rawTools.first?.readOnly == true)

        let echoed = AgentMCP.render(result: try await connection.callTool(name: "echo", arguments: ["text": "hi"]))
        #expect(echoed["output"] as? String == "http echo: hi")

        // The server drops every session: the next call gets 404, re-initialises once, and succeeds.
        _ = try await connection.callTool(name: "forget", arguments: [:])
        let again = AgentMCP.render(
            result: try await connection.callTool(name: "echo", arguments: ["text": "after expiry"]))
        #expect(again["output"] as? String == "http echo: after expiry")
    }

    @Test func headerValuesExpandSecretsAndEnvironment() {
        let expanded = MCPHTTPConnection.expand(
            "Bearer {{secret:GitHub}} / ${TEAM} / ${MISSING}",
            secret: { $0 == "github" ? "ghp_x" : nil },
            environment: ["TEAM": "voxos"])
        #expect(expanded == "Bearer ghp_x / voxos / ")
    }
}
