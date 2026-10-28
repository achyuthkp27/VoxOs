import Foundation
import Network
import os

/// The local endpoint Claude Code's hooks POST to (through curl, see ClaudeCodeHooks): a listener
/// on 127.0.0.1 only.
///
/// Status events are answered with an empty 200 straight away, on the bridge's own queue, so a
/// busy main thread never slows a tool call down. A PermissionRequest is held open until the
/// notch decides, the request is answered elsewhere, or it expires (see ClaudeCodeActivity).
///
/// When VoxOS is not running curl gets "connection refused" and the hook exits quietly with no
/// output: the session carries on and the terminal dialog works as it always does.
final class ClaudeCodeBridge: @unchecked Sendable {
    static let shared = ClaudeCodeBridge()

    enum State: Equatable {
        case stopped
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    /// Fixed so the URL written into ~/.claude/settings.json stays valid across launches.
    static let defaultPort: UInt16 = 47317
    /// Requests must carry this header. A browser cannot add a custom header to a cross-origin
    /// request without a CORS preflight, which this server never answers, so a web page cannot
    /// post events here.
    static let markerHeader = "X-VoxOS-Hook"
    /// The pid of the CLI that sent the event (see ClaudeCodeHooks.command).
    static let pidHeader = "X-VoxOS-CLI-PID"

    private let queue = DispatchQueue(label: "com.achyuthkp.voxos.claude-code-bridge")
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "ClaudeCodeBridge")
    private var listener: NWListener?
    private var port: UInt16 = defaultPort
    /// Read on the bridge queue; written through `setApprovalsEnabled`.
    private var approvalsEnabled = true

    /// Called on the main actor whenever the listener's state changes.
    var onStateChange: (@MainActor (State) -> Void)?

    private init() {}

    func start(port: UInt16 = defaultPort, approvalsEnabled: Bool) {
        queue.async { [self] in
            self.approvalsEnabled = approvalsEnabled
            if listener != nil, self.port == port { return }
            stopListener()
            self.port = port
            report(.starting)
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                parameters.requiredLocalEndpoint = .hostPort(
                    host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? 47317)
                let listener = try NWListener(using: parameters)
                listener.stateUpdateHandler = { [weak self] state in self?.listenerStateChanged(state) }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: queue)
                self.listener = listener
            } catch {
                logger.error("Claude Code bridge could not listen: \(error.localizedDescription, privacy: .public)")
                report(.failed(error.localizedDescription))
            }
        }
    }

    func stop() {
        queue.async { [self] in
            stopListener()
            report(.stopped)
        }
    }

    func setApprovalsEnabled(_ enabled: Bool) {
        queue.async { [self] in approvalsEnabled = enabled }
    }

    // MARK: Listener

    private func stopListener() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            logger.notice("Claude Code bridge listening on 127.0.0.1:\(self.port, privacy: .public)")
            report(.listening(port: port))
        case .failed(let error):
            logger.error("Claude Code bridge failed: \(error.localizedDescription, privacy: .public)")
            stopListener()
            report(.failed(Self.describe(error, port: port)))
        default:
            break
        }
    }

    private static func describe(_ error: NWError, port: UInt16) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE {
            return String(localized: "Port \(String(port)) is already in use by another app.")
        }
        return error.localizedDescription
    }

    private func report(_ state: State) {
        Task { @MainActor [weak self] in self?.onStateChange?(state) }
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch ClaudeCodeHTTP.parse(buffer) {
            case .complete(let request):
                self.route(request, on: connection)
            case .invalid:
                self.reply(400, on: connection)
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else if buffer.count > ClaudeCodeHTTP.maxRequestBytes {
                    self.reply(413, on: connection)
                } else {
                    self.receive(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func route(_ request: ClaudeCodeHTTP.Request, on connection: NWConnection) {
        let paths = [ClaudeCodeHooks.path, ClaudeCodeStatusRelay.path, CodexNotify.path]
        guard paths.contains(request.path) else { return reply(404, on: connection) }
        guard request.method == "POST" else { return reply(405, on: connection) }
        guard ClaudeCodeHTTP.isAllowedHost(request.headers["host"], port: port),
            request.headers[Self.markerHeader.lowercased()] != nil
        else { return reply(403, on: connection) }

        // The status line's input and Codex's turn ends: read, never answered with anything.
        if request.path != ClaudeCodeHooks.path {
            reply(200, on: connection)
            guard let object = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else { return }
            if request.path == ClaudeCodeStatusRelay.path {
                let reading = ClaudeCodeUsage.reading(from: object)
                Task { @MainActor in ClaudeCodeUsage.shared.receive(reading) }
            } else if let turnEnd = CodexActivity.turnEnd(from: object) {
                Task { @MainActor in CodexActivity.shared.turnEnded(project: turnEnd.project) }
            }
            return
        }

        // Anything VoxOS does not understand is acknowledged and ignored, never refused: a
        // non-2xx answer would show the user a hook error in the CLI.
        guard var event = ClaudeCodeHookEvent.decode(request.body) else { return reply(200, on: connection) }
        event.cliPID = request.headers[Self.pidHeader.lowercased()].flatMap { Int32($0) }.flatMap { $0 > 1 ? $0 : nil }

        guard event.kind == .permissionRequest, approvalsEnabled else {
            reply(200, on: connection)
            Task { @MainActor in ClaudeCodeActivity.shared.receive(event) }
            return
        }

        Task { @MainActor [weak self] in
            let id = ClaudeCodeActivity.shared.request(event) { resolution in
                self?.queue.async { self?.answer(resolution, to: event, on: connection) }
            }
            self?.queue.async { self?.watchForClose(connection, prompt: id) }
        }
    }

    /// A held connection has nothing more to send, so any completed read means the CLI closed it.
    private func watchForClose(_ connection: NWConnection, prompt id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil {
                Task { @MainActor in ClaudeCodeActivity.shared.connectionClosed(id) }
            } else {
                self?.watchForClose(connection, prompt: id)
            }
        }
    }

    private func answer(
        _ resolution: ClaudeCodeActivity.Resolution, to event: ClaudeCodeHookEvent, on connection: NWConnection
    ) {
        switch resolution {
        case .noDecision:
            reply(200, on: connection)
        case .decided(let decision):
            reply(200, body: Self.decisionBody(decision, for: event), on: connection)
        }
    }

    /// The PermissionRequest output for a decision (see the hooks reference, "PermissionRequest
    /// decision control"). Answers to AskUserQuestion echo the questions back with an `answers`
    /// map; allowing alone does not answer them. A plan sent back carries what to change as the
    /// denial's message, which is how the terminal's "No, keep planning" feedback reaches Claude.
    static func decisionBody(_ decision: ClaudeCodeActivity.Decision, for event: ClaudeCodeHookEvent) -> Data {
        var verdict: [String: Any] = ["behavior": "allow"]
        switch decision {
        case .allow:
            break
        case .allowAlways:
            let suggestions = event.permissionSuggestions
            if !suggestions.isEmpty { verdict["updatedPermissions"] = suggestions }
        case .allowInAutoMode:
            verdict["updatedPermissions"] = [["type": "setMode", "mode": "auto", "destination": "session"]]
        case .deny:
            verdict = ["behavior": "deny", "message": "The user denied this from the VoxOS notch."]
        case .answer(let answers):
            var input = event.toolInput
            input["answers"] = answers
            verdict["updatedInput"] = input
        case .approvePlan(let acceptEdits):
            // The terminal's "Yes, auto-accept edits" is this same mode change.
            if acceptEdits {
                verdict["updatedPermissions"] = [["type": "setMode", "mode": "acceptEdits", "destination": "session"]]
            }
        case .keepPlanning(let feedback):
            let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
            verdict = [
                "behavior": "deny",
                "message": text.isEmpty
                    ? "The user wants to keep planning before approving this plan." : "Keep planning: \(text)",
            ]
        }
        let output: [String: Any] = [
            "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": verdict]
        ]
        return (try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])) ?? Data()
    }

    private func reply(_ status: Int, body: Data = Data(), on connection: NWConnection) {
        connection.send(
            content: ClaudeCodeHTTP.response(status: status, body: body),
            completion: .contentProcessed { _ in connection.cancel() })
    }
}
