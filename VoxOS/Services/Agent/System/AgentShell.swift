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

                var output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
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

        let patterns: [(String, String)] = [
            ("rm -rf", "recursive force-delete"), ("rm -fr", "recursive force-delete"),
            ("rm -r -f", "recursive force-delete"), ("rm -f -r", "recursive force-delete"),
            ("rm --no-preserve-root", "delete from the filesystem root"),
            ("sudo ", "runs as root"), ("doas ", "runs as root"),
            ("mkfs", "formats a filesystem"), ("dd if=", "raw disk read/write"),
            ("of=/dev/", "raw disk write"), ("> /dev/", "writes to a device file"),
            ("shutdown", "powers off the machine"), ("halt", "powers off the machine"),
            ("reboot", "reboots the machine"),
            ("diskutil erase", "erases a disk"), ("diskutil reformat", "reformats a disk"),
            (":(){:|:&};:", "fork bomb"), (":(){ :|:& };:", "fork bomb"),
            ("csrutil disable", "disables System Integrity Protection"),
            ("spctl --master-disable", "disables Gatekeeper"),
            ("launchctl unload", "unloads a system service"),
            ("killall -9", "force-kills processes"),
        ]
        for (needle, reason) in patterns where collapsed.contains(needle) { return reason }

        let downloads = collapsed.contains("curl ") || collapsed.contains("wget ")
        let pipedToShell = collapsed.contains("| sh") || collapsed.contains("| bash") || collapsed.contains("|sh") || collapsed.contains("|bash")
        if downloads, pipedToShell { return "pipes a download straight into a shell" }
        return nil
    }
}
