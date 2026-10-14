import Foundation

/// Keeps one Claude Code process started ahead of time for the Local CLI provider.
///
/// Starting `claude -p` costs ~2 s before the model is even asked (measured on an M4 Pro:
/// ~3 s cold vs ~1.2 s on a pre-started process). A spare is started while the user is idle,
/// answers exactly one request through Claude Code's stream-json input, and is then replaced,
/// so every request is a fresh conversation and no earlier dictation leaks into the next.
///
/// It runs only while Local CLI is chosen somewhere (main or fallback model, or a mode's AI
/// provider) and the command is the built-in Claude template, whose flags are known. There is
/// no timed restart: a spare is replaced after it is used or after it fails, and a spare that
/// exits on its own is not restarted until the next request, so a broken login cannot loop.
final class LocalCLIWarmClaude {
    static let shared = LocalCLIWarmClaude()

    /// The built-in template's flags, in stream-json form; `exec` so the process is Claude
    /// itself and closes with its stdin when VoxOS quits or crashes.
    static let streamingCommand =
        "exec claude -p --input-format stream-json --output-format stream-json --verbose --model haiku --strict-mcp-config --setting-sources \"\" --disable-slash-commands --no-session-persistence --tools \"\""

    /// Only the built-in Claude template runs warm; an edited command runs exactly as written.
    static func isEligible(command: String) -> Bool {
        command == LocalCLITemplate.claude.commandTemplate
    }

    private let lock = NSLock()
    private var spare: Spare?
    private var wanted = false
    private var observers: [NSObjectProtocol] = []
    private var pendingRefresh: DispatchWorkItem?

    /// Whether Local CLI is chosen as the main or fallback model or as an enabled mode's provider.
    static func isLocalCLIInUse(main: AIModelChoice?, fallback: AIModelChoice?, modes: [ModeConfig]) -> Bool {
        main?.provider == .localCLI || fallback?.provider == .localCLI
            || modes.contains { $0.isAIEnhancementEnabled && $0.selectedAIProvider == AIProvider.localCLI.rawValue }
    }

    /// Keeps the spare in step with the settings: checked at launch and after any settings or
    /// mode change, debounced, since every UserDefaults write posts a change.
    func startMonitoring(command: @escaping () -> String) {
        let refresh = { [weak self] in self?.scheduleRefresh(command: command) }
        observers = [
            NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in refresh() }
        ]
        refresh()
    }

    private func scheduleRefresh(command: @escaping () -> String) {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            let inUse = Self.isLocalCLIInUse(
                main: AIModelRouting.main, fallback: AIModelRouting.fallback,
                modes: ModeManager.shared.configurations)
            self?.setWanted(inUse && Self.isEligible(command: command()))
        }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// Starts or stops the spare to match whether Local CLI is in use.
    func setWanted(_ wanted: Bool) {
        let toStop: Spare? = lock.withLock {
            guard self.wanted != wanted else { return nil }
            self.wanted = wanted
            guard !wanted else { return nil }
            defer { spare = nil }
            return spare
        }
        toStop?.stop()
        if wanted { replenish() }
    }

    /// Stops the spare for good, at quit.
    func shutdown() {
        setWanted(false)
    }

    /// Answers `prompt` on the spare, or returns nil when there is none ready (the caller then
    /// runs the command the normal way). Throws when the spare failed mid-request.
    func complete(prompt: String, timeout: TimeInterval) async throws -> String? {
        let taken: Spare? = lock.withLock {
            defer { spare = nil }
            return spare?.isRunning == true ? spare : nil
        }
        guard let taken else {
            replenish()
            return nil
        }
        defer {
            taken.stop()
            replenish()
        }
        return try await taken.send(prompt, timeout: timeout)
    }

    private func replenish() {
        DispatchQueue.global(qos: .utility).async { [self] in
            let shouldStart = lock.withLock { wanted && spare == nil }
            guard shouldStart, let started = Spare.start() else { return }
            let keep = lock.withLock { () -> Bool in
                guard wanted, spare == nil else { return false }
                spare = started
                return true
            }
            if !keep { started.stop() }
        }
    }
}

extension LocalCLIWarmClaude {
    enum WarmError: LocalizedError {
        case failed(String)
        case timedOut(TimeInterval)
        case exited

        var errorDescription: String? {
            switch self {
            case .failed(let message): return message
            case .timedOut(let seconds): return "Claude did not answer within \(Int(seconds)) s"
            case .exited: return "Claude exited before answering"
            }
        }
    }

    /// Builds the stream-json user message for one request.
    static func userMessageLine(_ prompt: String) -> String? {
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": prompt]]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        return String(data: data, encoding: .utf8).map { $0 + "\n" }
    }

    /// The answer carried by one stream-json output line, if that line is the final result.
    static func result(fromLine line: String) -> Result<String, WarmError>? {
        guard let data = line.data(using: .utf8),
            let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            event["type"] as? String == "result"
        else { return nil }
        let text = ((event["result"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if event["is_error"] as? Bool == true || text.isEmpty {
            return .failure(.failed(text.isEmpty ? "Claude returned no text" : text))
        }
        return .success(text)
    }

    fileprivate final class Spare {
        private let process: Process
        private let input: FileHandle
        private let output: FileHandle
        private let lock = NSLock()
        private var buffer = Data()
        private var completion: ((Result<String, WarmError>) -> Void)?

        var isRunning: Bool { process.isRunning }

        private init(process: Process, input: FileHandle, output: FileHandle) {
            self.process = process
            self.input = input
            self.output = output
        }

        static func start() -> Spare? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", LocalCLIWarmClaude.streamingCommand]
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = ShellCommandEnvironment.preferredPATH(fallback: environment["PATH"])
            process.environment = environment

            let inputPipe = Pipe()
            let outputPipe = Pipe()
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice

            let spare = Spare(
                process: process, input: inputPipe.fileHandleForWriting, output: outputPipe.fileHandleForReading)
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                spare.received(handle.availableData)
            }
            process.terminationHandler = { _ in spare.finish(.failure(.exited)) }
            do {
                try process.run()
            } catch {
                return nil
            }
            return spare
        }

        func send(_ prompt: String, timeout: TimeInterval) async throws -> String {
            guard let line = LocalCLIWarmClaude.userMessageLine(prompt), let data = line.data(using: .utf8) else {
                throw WarmError.failed("could not encode the request")
            }
            return try await withCheckedThrowingContinuation { continuation in
                lock.withLock { completion = { continuation.resume(with: $0) } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                    self?.finish(.failure(.timedOut(timeout)))
                }
                do {
                    try input.write(contentsOf: data)
                } catch {
                    finish(.failure(.failed(error.localizedDescription)))
                }
            }
        }

        func stop() {
            output.readabilityHandler = nil
            try? input.close()
            if process.isRunning { process.terminate() }
        }

        private func received(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            var results: [Result<String, WarmError>] = []
            lock.withLock {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let line = String(data: lineData, encoding: .utf8),
                        let result = LocalCLIWarmClaude.result(fromLine: line)
                    {
                        results.append(result)
                    }
                }
            }
            results.first.map(finish)
        }

        /// Delivers the first outcome only; later ones (timeout after success, exit) are ignored.
        private func finish(_ result: Result<String, WarmError>) {
            let pending = lock.withLock { () -> ((Result<String, WarmError>) -> Void)? in
                defer { completion = nil }
                return completion
            }
            pending?(result)
        }
    }
}
