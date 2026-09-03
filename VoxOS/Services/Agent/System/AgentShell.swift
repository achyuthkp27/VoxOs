import Foundation

/// Runs shell commands and AppleScript for the agent — the escape hatch for anything
/// without a dedicated tool. Commands matching a risky pattern are blocked unless the user
/// opts in via Settings → Agent → "Allow risky shell commands".
/// Ported from cursor-voice (MIT) ShellRunner.
enum AgentShell {
    static let timeoutSeconds: Double = 30
    static let allowRiskyKey = "agentAllowRiskyShellCommands"

    static func run(_ command: String) async -> [String: Any] {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ["error": "command is required"] }

        let risk = riskReason(trimmed)
        let allowRisky = UserDefaults.standard.bool(forKey: allowRiskyKey)
        if let risk, !allowRisky {
            return [
                "blocked": true,
                "risk": risk,
                "error": "blocked: this command looks risky (\(risk)) and was NOT run. The user can enable “Allow risky shell commands” in Settings → Agent and ask again.",
            ]
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-l", "-c", trimmed]
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: ["error": error.localizedDescription])
                    return
                }

                // Drain the pipe while the process runs; waiting first would deadlock any
                // command whose output exceeds the pipe buffer.
                let collected = NSMutableData()
                let collectLock = NSLock()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else { return }
                    collectLock.lock(); collected.append(chunk); collectLock.unlock()
                }

                var timedOut = false
                let watchdog = DispatchWorkItem {
                    if process.isRunning {
                        timedOut = true
                        process.terminate()
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: watchdog)
                process.waitUntilExit()
                watchdog.cancel()
                usleep(50_000)  // let the last readability callback land
                pipe.fileHandleForReading.readabilityHandler = nil
                collectLock.lock()
                var output = String(data: collected as Data, encoding: .utf8) ?? ""
                collectLock.unlock()
                if output.count > 4000 { output = String(output.prefix(4000)) + "\n…(truncated)" }

                var result: [String: Any] = ["exit": Int(process.terminationStatus), "output": output]
                if timedOut { result["error"] = "timed out after \(Int(timeoutSeconds))s" }
                if let risk { result["warning"] = "ran a risky command (\(risk)) — permitted by the user's setting" }
                continuation.resume(returning: result)
            }
        }
    }

    /// Short reason if the command matches a risky pattern. A pattern list can't catch
    /// everything, which is why it is paired with the opt-in rather than being a hard wall.
    static func riskReason(_ command: String) -> String? {
        let collapsed = command.lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        // Word-boundary patterns so "2> /dev/null" and "shutdown-notes.txt" do not trip the gate.
        // The prefix class includes quotes/parens too, since a command is often wrapped as
        // `zsh -c "shutdown -h now"` or `(shutdown now)` — quoting must not defeat the gate.
        let b = #"(^|[;&|\s"'(])"#
        let e = #"(\s|$|["')])"#
        let patterns: [(String, String)] = [
            (#"\brm\s+(-[a-z]*r[a-z]*f|-[a-z]*f[a-z]*r|-r\s+-f|-f\s+-r)\b"#, "recursive force-delete"),
            (#"\brm\b.*--no-preserve-root"#, "delete from the filesystem root"),
            (b + #"sudo\s"#, "runs as root"), (b + #"doas\s"#, "runs as root"),
            (#"\bmkfs(\.|\b)"#, "formats a filesystem"), (#"\bdd\s+.*\bif="#, "raw disk read/write"),
            (#"\bof=/dev/"#, "raw disk write"), (#">\s*/dev/(?!null\b)"#, "writes to a device file"),
            (b + "shutdown" + e, "powers off the machine"), (b + "halt" + e, "powers off the machine"),
            (b + "reboot" + e, "reboots the machine"),
            (#"\bdiskutil\s+(erase|reformat|partition)"#, "erases a disk"),
            (#":\(\)\s*\{\s*:\|:&\s*\};:"#, "fork bomb"),
            (#"\bcsrutil\s+disable"#, "disables System Integrity Protection"),
            (#"\bspctl\s+--master-disable"#, "disables Gatekeeper"),
            (#"\blaunchctl\s+(unload|bootout)\b"#, "unloads a system service"),
            (#"\bkillall\s+-9\b"#, "force-kills processes"),
            (#"administrator privileges"#, "runs as root"),
        ]
        for (pattern, reason) in patterns where collapsed.range(of: pattern, options: .regularExpression) != nil { return reason }

        let downloads = collapsed.contains("curl ") || collapsed.contains("wget ")
        let pipedToShell = collapsed.contains("| sh") || collapsed.contains("| bash") || collapsed.contains("|sh") || collapsed.contains("|bash")
        if downloads, pipedToShell { return "pipes a download straight into a shell" }
        return nil
    }
}
