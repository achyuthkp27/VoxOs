import Foundation
import os

/// One configured MCP server, in the same shape Claude Desktop and most MCP docs use:
/// `{"mcpServers": {"notion": {"command": "npx", "args": [...], "env": {...}}}}`.
struct MCPServerConfig: Equatable {
    let name: String
    let command: String
    let args: [String]
    let env: [String: String]
    let disabled: Bool
    /// Remote (HTTP) servers need OAuth flows VoxOS does not implement yet.
    let remoteURL: String?

    var isSupported: Bool { remoteURL == nil && !command.isEmpty }
}

/// A tool advertised by an MCP server.
struct MCPTool {
    let server: String
    let name: String
    /// What the agent calls it: `mcp_<server>_<tool>`, unique across servers.
    let exposedName: String
    let description: String
    let inputSchema: [String: Any]
    /// The server's `readOnlyHint`. Read-only tools skip the control-mode gate.
    let readOnly: Bool
}

enum MCPError: LocalizedError {
    case commandNotFound(String)
    case notRunning
    case timeout(String)
    case exited(String)
    case rpc(Int, String)
    case badMessage

    var errorDescription: String? {
        switch self {
        case .commandNotFound(let command):
            return "command not found: \(command). Install it or use a full path in the MCP config."
        case .notRunning: return "the server is not running"
        case .timeout(let method): return "the server did not answer \(method) in time"
        case .exited(let detail): return detail.isEmpty ? "the server exited" : "the server exited: \(detail)"
        case .rpc(let code, let message): return "server error \(code): \(message)"
        case .badMessage: return "could not encode the request"
        }
    }
}

/// Returns whichever finishes first: the work, or nil after `seconds`. Unlike a task group,
/// it does not wait for the loser, so work that ignores cancellation cannot stall the caller.
func mcpRace<T: Sendable>(seconds: TimeInterval, _ work: @escaping @Sendable () async -> T) async -> T? {
    let gate = MCPResumeOnce<T?>()
    return await withCheckedContinuation { continuation in
        gate.install(continuation)
        Task { gate.resume(await work()) }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            gate.resume(nil)
        }
    }
}

final class MCPResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    func install(_ continuation: CheckedContinuation<T, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func resume(_ value: T) {
        let pending = lock.withLock { () -> CheckedContinuation<T, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

/// `@unchecked Sendable` wrapper so JSON dictionaries can cross continuation boundaries.
struct MCPJSON: @unchecked Sendable {
    let value: [String: Any]
}

/// A stdio MCP connection: spawns the server, speaks newline-delimited JSON-RPC 2.0 over its
/// stdin/stdout, and exposes `initialize`, `tools/list` and `tools/call`.
/// All mutable state sits behind one lock; pipe callbacks arrive on arbitrary queues.
final class MCPConnection: @unchecked Sendable {

    enum State: Equatable {
        case idle
        case starting
        case ready
        case failed(String)
    }

    static let protocolVersion = "2025-06-18"

    let config: MCPServerConfig

    private let lock = NSLock()
    private var process: Process?
    private var stdinHandle: FileHandle?
    private var readBuffer = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<MCPJSON, Error>] = [:]
    private var _state: State = .idle
    private var _tools: [(name: String, description: String, schema: [String: Any], readOnly: Bool)] = []
    private var stderrTail = ""
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "MCP")

    /// Called (off the main thread) when the state or tool list changes.
    var onChange: (@Sendable () -> Void)?

    init(config: MCPServerConfig) {
        self.config = config
    }

    deinit {
        process?.terminate()
    }

    var state: State { lock.withLock { _state } }

    var rawTools: [(name: String, description: String, schema: [String: Any], readOnly: Bool)] {
        lock.withLock { _tools }
    }

    // MARK: - Lifecycle

    func start(path: String) async throws {
        MCPConnection.ignoreSIGPIPE()
        setState(.starting)

        guard let executable = Self.resolve(command: config.command, path: path) else {
            let error = MCPError.commandNotFound(config.command)
            setState(.failed(error.localizedDescription))
            throw error
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = config.args
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        for (key, value) in config.env { environment[key] = value }
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.receive(chunk)
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.appendStderr(chunk)
        }
        process.terminationHandler = { [weak self] finished in
            self?.handleExit(status: finished.terminationStatus)
        }

        // Register before launching: a server that dies instantly must find these set, or its
        // termination would be recorded first and the handshake would wait for the full timeout.
        lock.withLock {
            self.process = process
            self.stdinHandle = stdin.fileHandleForWriting
        }
        do {
            try process.run()
        } catch {
            lock.withLock {
                self.process = nil
                self.stdinHandle = nil
            }
            setState(.failed(error.localizedDescription))
            throw error
        }

        do {
            _ = try await request(
                "initialize",
                params: [
                    "protocolVersion": Self.protocolVersion,
                    "capabilities": [String: Any](),
                    "clientInfo": ["name": "VoxOS", "version": "1.0"],
                ],
                // npx may download the server package on first launch.
                timeout: 90)
            try notify("notifications/initialized")
            try await refreshTools()
            setState(.ready)
        } catch {
            let detail = error.localizedDescription
            stop()
            setState(.failed(detail))
            throw error
        }
    }

    func stop() {
        let (process, stdin, waiting) = lock.withLock { () -> (Process?, FileHandle?, [CheckedContinuation<MCPJSON, Error>]) in
            let snapshot = (self.process, self.stdinHandle, Array(self.pending.values))
            self.process = nil
            self.stdinHandle = nil
            self.pending = [:]
            return snapshot
        }
        process?.terminationHandler = nil
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        (process?.standardError as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        try? stdin?.close()
        if process?.isRunning == true { process?.terminate() }
        for continuation in waiting { continuation.resume(throwing: MCPError.notRunning) }
        if case .ready = state { setState(.idle) }
    }

    // MARK: - Tools

    func refreshTools() async throws {
        var collected: [(name: String, description: String, schema: [String: Any], readOnly: Bool)] = []
        var cursor: String?
        var pages = 0
        repeat {
            let params: [String: Any] = cursor.map { ["cursor": $0] } ?? [:]
            let result = try await request("tools/list", params: params, timeout: 30)
            for tool in (result["tools"] as? [[String: Any]]) ?? [] {
                guard let name = tool["name"] as? String, !name.isEmpty else { continue }
                let annotations = tool["annotations"] as? [String: Any]
                collected.append(
                    (
                        name: name,
                        description: (tool["description"] as? String) ?? "",
                        schema: (tool["inputSchema"] as? [String: Any]) ?? [:],
                        readOnly: (annotations?["readOnlyHint"] as? Bool) ?? false
                    ))
            }
            cursor = result["nextCursor"] as? String
            pages += 1
        } while cursor != nil && pages < 20
        lock.withLock { _tools = collected }
        onChange?()
    }

    func callTool(name: String, arguments: [String: Any], timeout: TimeInterval = 90) async throws -> [String: Any] {
        try await request("tools/call", params: ["name": name, "arguments": arguments], timeout: timeout)
    }

    // MARK: - JSON-RPC

    func request(_ method: String, params: [String: Any]?, timeout: TimeInterval) async throws -> [String: Any] {
        let id = lock.withLock { () -> Int in
            defer { nextID += 1 }
            return nextID
        }
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }

        let box = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MCPJSON, Error>) in
            let running = lock.withLock { () -> Bool in
                guard process != nil else { return false }
                pending[id] = continuation
                return true
            }
            guard running else {
                continuation.resume(throwing: MCPError.notRunning)
                return
            }
            do {
                try write(message)
            } catch {
                takePending(id)?.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.takePending(id)?.resume(throwing: MCPError.timeout(method))
            }
        }
        return box.value
    }

    private func notify(_ method: String, params: [String: Any]? = nil) throws {
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { message["params"] = params }
        try write(message)
    }

    private func write(_ message: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(message) else { throw MCPError.badMessage }
        // Compact serialisation never contains a raw newline, which is the message delimiter.
        var data = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        data.append(0x0A)
        guard let handle = lock.withLock({ stdinHandle }) else { throw MCPError.notRunning }
        try handle.write(contentsOf: data)
    }

    private func takePending(_ id: Int) -> CheckedContinuation<MCPJSON, Error>? {
        lock.withLock { pending.removeValue(forKey: id) }
    }

    private func receive(_ chunk: Data) {
        let lines = lock.withLock { () -> [Data] in
            readBuffer.append(chunk)
            var lines: [Data] = []
            while let newline = readBuffer.firstIndex(of: 0x0A) {
                lines.append(readBuffer[readBuffer.startIndex..<newline])
                readBuffer.removeSubrange(readBuffer.startIndex...newline)
            }
            return lines
        }
        for line in lines where !line.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                logger.debug("[\(self.config.name, privacy: .public)] ignoring non-JSON stdout line")
                continue
            }
            handle(object)
        }
    }

    private func handle(_ message: [String: Any]) {
        let method = message["method"] as? String
        let rawID = message["id"]

        if method == nil, let rawID {
            // Response to one of our requests. IDs we send are Ints; accept any numeric form.
            guard let id = (rawID as? NSNumber)?.intValue ?? (rawID as? String).flatMap(Int.init),
                let continuation = takePending(id)
            else { return }
            if let error = message["error"] as? [String: Any] {
                continuation.resume(
                    throwing: MCPError.rpc((error["code"] as? Int) ?? -1, (error["message"] as? String) ?? "unknown error"))
            } else {
                continuation.resume(returning: MCPJSON(value: (message["result"] as? [String: Any]) ?? [:]))
            }
            return
        }

        guard let method else { return }

        if let rawID {
            // A request from the server. VoxOS offers no client capabilities beyond ping.
            var response: [String: Any] = ["jsonrpc": "2.0", "id": rawID]
            switch method {
            case "ping":
                response["result"] = [String: Any]()
            case "roots/list":
                response["result"] = ["roots": [Any]()]
            default:
                response["error"] = ["code": -32601, "message": "method not supported by VoxOS: \(method)"]
            }
            try? write(response)
            return
        }

        if method == "notifications/tools/list_changed" {
            Task { [weak self] in try? await self?.refreshTools() }
        }
    }

    private func appendStderr(_ chunk: Data) {
        let text = String(decoding: chunk, as: UTF8.self)
        lock.withLock {
            stderrTail = String((stderrTail + text).suffix(600))
        }
    }

    private func handleExit(status: Int32) {
        let (waiting, tail) = lock.withLock { () -> ([CheckedContinuation<MCPJSON, Error>], String) in
            let waiting = Array(pending.values)
            pending = [:]
            process = nil
            stdinHandle = nil
            return (waiting, stderrTail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let lastLine = tail.split(separator: "\n").last.map(String.init) ?? ""
        let detail = lastLine.isEmpty ? "exit status \(status)" : lastLine
        for continuation in waiting { continuation.resume(throwing: MCPError.exited(detail)) }
        logger.notice("[\(self.config.name, privacy: .public)] exited: \(detail, privacy: .public)")
        setState(.failed(detail))
    }

    private func setState(_ newState: State) {
        let changed = lock.withLock { () -> Bool in
            guard _state != newState else { return false }
            _state = newState
            return true
        }
        if changed { onChange?() }
    }

    // MARK: - Helpers

    static func resolve(command: String, path: String) -> URL? {
        let fm = FileManager.default
        if command.contains("/") {
            let expanded = (command as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }
        for directory in path.split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(command)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static let sigpipeOnce: Void = {
        // Writing to a server that just died must return EPIPE, not kill VoxOS.
        signal(SIGPIPE, SIG_IGN)
    }()

    static func ignoreSIGPIPE() { _ = sigpipeOnce }
}
