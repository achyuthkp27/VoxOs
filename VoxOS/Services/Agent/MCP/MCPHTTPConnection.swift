import Foundation
import os

/// A remote MCP server over Streamable HTTP: every JSON-RPC message is a POST to one URL, and
/// the server answers with either a JSON body or a server-sent-events stream that carries the
/// response (possibly after its own requests, such as ping). The session id the server hands
/// out on `initialize` is echoed on every later request; an expired session is re-opened once.
final class MCPHTTPConnection: MCPClient, @unchecked Sendable {

    let config: MCPServerConfig
    var onChange: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var _state: MCPConnection.State = .idle
    private var _tools: [(name: String, description: String, schema: [String: Any], readOnly: Bool)] = []
    private var sessionID: String?
    private var negotiatedVersion: String?
    private var nextID = 1
    private let session: URLSession
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "MCP")

    init(config: MCPServerConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    var state: MCPConnection.State { lock.withLock { _state } }

    var rawTools: [(name: String, description: String, schema: [String: Any], readOnly: Bool)] {
        lock.withLock { _tools }
    }

    // MARK: - Lifecycle

    func start(path _: String) async throws {
        setState(.starting)
        do {
            try await initialize()
            try await refreshTools()
            setState(.ready)
        } catch {
            setState(.failed(error.localizedDescription))
            throw error
        }
    }

    func stop() {
        let (endpoint, session) = lock.withLock { () -> (URL?, String?) in
            defer {
                sessionID = nil
                negotiatedVersion = nil
            }
            return (URL(string: config.remoteURL ?? ""), sessionID)
        }
        // Politely end the session; servers that do not support DELETE simply ignore it.
        if let endpoint, let session {
            var request = URLRequest(url: endpoint, timeoutInterval: 5)
            request.httpMethod = "DELETE"
            request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id")
            applyHeaders(to: &request)
            self.session.dataTask(with: request).resume()
        }
        if case .ready = state { setState(.idle) }
    }

    func refreshTools() async throws {
        var collected: [(name: String, description: String, schema: [String: Any], readOnly: Bool)] = []
        var cursor: String?
        var pages = 0
        repeat {
            let result = try await request("tools/list", params: cursor.map { ["cursor": $0] } ?? [:], timeout: 30)
            collected += Self.parseTools(result)
            cursor = result["nextCursor"] as? String
            pages += 1
        } while cursor != nil && pages < 20
        lock.withLock { _tools = collected }
        onChange?()
    }

    func callTool(name: String, arguments: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        try await request("tools/call", params: ["name": name, "arguments": arguments], timeout: timeout)
    }

    // MARK: - JSON-RPC over HTTP

    private func initialize() async throws {
        lock.withLock {
            sessionID = nil
            negotiatedVersion = nil
        }
        let result = try await send(
            method: "initialize",
            params: [
                "protocolVersion": MCPConnection.protocolVersion,
                "capabilities": [String: Any](),
                "clientInfo": ["name": "VoxOS", "version": "1.0"],
            ],
            timeout: 30, allowReinitialize: false)
        lock.withLock { negotiatedVersion = (result["protocolVersion"] as? String) ?? MCPConnection.protocolVersion }
        try await notify("notifications/initialized")
    }

    func request(_ method: String, params: [String: Any]?, timeout: TimeInterval) async throws -> [String: Any] {
        try await send(method: method, params: params, timeout: timeout, allowReinitialize: true)
    }

    private func send(method: String, params: [String: Any]?, timeout: TimeInterval, allowReinitialize: Bool)
        async throws
        -> [String: Any]
    {
        let id = lock.withLock { () -> Int in
            defer { nextID += 1 }
            return nextID
        }
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }

        let (bytes, response) = try await post(message, timeout: timeout)
        guard let http = response as? HTTPURLResponse else { throw MCPError.badMessage }

        if http.statusCode == 404, allowReinitialize, lock.withLock({ sessionID != nil }) {
            // The server forgot our session (restart, expiry): open a new one and retry once.
            try await initialize()
            return try await send(method: method, params: params, timeout: timeout, allowReinitialize: false)
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw MCPError.rpc(
                http.statusCode, "not authorised — add an Authorization header (browser sign-in is not supported)")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = try await Self.collect(bytes, limit: 400)
            throw MCPError.rpc(
                http.statusCode, body.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: http.statusCode) : body)
        }

        if let issued = http.value(forHTTPHeaderField: "Mcp-Session-Id"), !issued.isEmpty {
            lock.withLock { sessionID = issued }
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/event-stream") {
            // URLRequest's timeout is an inactivity timer; a server sending keep-alive comments
            // while wedged would otherwise hold this call open forever.
            let outcome: Result<[String: Any], Error>? = await mcpRace(seconds: timeout) {
                do {
                    return .success(try await self.readStream(bytes, awaiting: id))
                } catch {
                    return .failure(error)
                }
            }
            guard let outcome else { throw MCPError.timeout(method) }
            return try outcome.get()
        }
        let body = try await Self.collect(bytes, limit: 8_000_000)
        guard let object = try? JSONSerialization.jsonObject(with: Data(body.utf8)) else { throw MCPError.badMessage }
        // A JSON body may be a single response or a batch containing it.
        let messages = (object as? [[String: Any]]) ?? [(object as? [String: Any]) ?? [:]]
        guard let matched = messages.first(where: { Self.id(of: $0) == id }) else { throw MCPError.badMessage }
        return try Self.unwrap(matched)
    }

    private func notify(_ method: String) async throws {
        let (_, response) = try await post(["jsonrpc": "2.0", "method": method], timeout: 15)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MCPError.rpc((response as? HTTPURLResponse)?.statusCode ?? -1, "\(method) was rejected")
        }
    }

    private func post(_ message: [String: Any], timeout: TimeInterval) async throws -> (
        URLSession.AsyncBytes, URLResponse
    ) {
        guard let endpoint = URL(string: config.remoteURL ?? "") else { throw MCPError.badMessage }
        guard JSONSerialization.isValidJSONObject(message) else { throw MCPError.badMessage }
        var request = URLRequest(url: endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let (session, version) = lock.withLock { (sessionID, negotiatedVersion) }
        if let session { request.setValue(session, forHTTPHeaderField: "Mcp-Session-Id") }
        if let version { request.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version") }
        applyHeaders(to: &request)
        do {
            return try await self.session.bytes(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw MCPError.timeout((message["method"] as? String) ?? "request")
        }
    }

    /// Reads SSE events until the response to `id` arrives, answering server pings on the way.
    /// `AsyncBytes.lines` omits the blank lines that separate events, so an event is taken to
    /// be complete as soon as its accumulated `data:` lines form a JSON value.
    private func readStream(_ bytes: URLSession.AsyncBytes, awaiting id: Int) async throws -> [String: Any] {
        var dataLines: [String] = []
        for try await line in bytes.lines {
            // An empty line ends an event. Other fields (`id:`, `retry:`, `:` comments) may sit
            // between the data lines of one event and must not discard what was accumulated.
            if line.isEmpty {
                dataLines = []
                continue
            }
            guard line.hasPrefix("data:") else { continue }
            var value = Substring(line.dropFirst(5))
            // SSE strips exactly one leading space; anything else is payload.
            if value.first == " " { value = value.dropFirst() }
            dataLines.append(String(value))
            let payload = dataLines.joined(separator: "\n")
            guard (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) != nil else { continue }
            dataLines = []
            if let result = try handleEvent(payload, awaiting: id) { return result }
        }
        throw MCPError.exited("the stream ended before the server answered")
    }

    private func handleEvent(_ payload: String, awaiting id: Int) throws -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else {
            return nil
        }
        if object["method"] == nil, Self.id(of: object) == id {
            return try Self.unwrap(object)
        }
        if let method = object["method"] as? String, let rawID = object["id"] {
            var reply: [String: Any] = ["jsonrpc": "2.0", "id": rawID]
            if method == "ping" {
                reply["result"] = [String: Any]()
            } else {
                reply["error"] = ["code": -32601, "message": "method not supported by VoxOS: \(method)"]
            }
            Task { _ = try? await self.post(reply, timeout: 10) }
        } else if object["method"] as? String == "notifications/tools/list_changed" {
            Task { try? await self.refreshTools() }
        }
        return nil
    }

    // MARK: - Helpers

    /// Header values may reference Keychain secrets (`{{secret:github}}`) or environment
    /// variables (`${GITHUB_TOKEN}`), so tokens need not live in the config file.
    private func applyHeaders(to request: inout URLRequest) {
        for (name, value) in config.headers {
            request.setValue(Self.expand(value), forHTTPHeaderField: name)
        }
    }

    static func expand(
        _ value: String,
        secret: (String) -> String? = { KeychainService.shared.getString(forKey: "AgentSecret.\($0)") },
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let secretsReplaced = replace(in: value, pattern: #"\{\{secret:([a-zA-Z0-9_.-]+)\}\}"#) {
            secret($0.lowercased()) ?? ""
        }
        return replace(in: secretsReplaced, pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"#) { environment[$0] ?? "" }
    }

    private static func replace(in text: String, pattern: String, with lookup: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = text
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let name = ns.substring(with: match.range(at: 1))
            result = (result as NSString).replacingCharacters(in: match.range, with: lookup(name))
        }
        return result
    }

    private static func id(of message: [String: Any]) -> Int? {
        (message["id"] as? NSNumber)?.intValue ?? (message["id"] as? String).flatMap(Int.init)
    }

    private static func unwrap(_ message: [String: Any]) throws -> [String: Any] {
        if let error = message["error"] as? [String: Any] {
            throw MCPError.rpc((error["code"] as? Int) ?? -1, (error["message"] as? String) ?? "unknown error")
        }
        return (message["result"] as? [String: Any]) ?? [:]
    }

    private static func collect(_ bytes: URLSession.AsyncBytes, limit: Int) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func setState(_ newState: MCPConnection.State) {
        let changed = lock.withLock { () -> Bool in
            guard _state != newState else { return false }
            _state = newState
            return true
        }
        if changed { onChange?() }
    }
}
