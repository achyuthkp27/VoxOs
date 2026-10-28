import Darwin
import Foundation

/// A direct child of a Claude Code CLI process.
struct ClaudeCodeChildProcess: Equatable {
    let pid: Int32
    /// The process's arguments joined with spaces.
    let arguments: String
}

/// Reads a CLI's child processes, which is how VoxOS sees a Bash command that was allowed in the
/// terminal start running.
///
/// "Yes" in the terminal sends nothing until the tool has finished (PostToolUse), so a long
/// command approved there would keep its card up for as long as it runs. The CLI starts an
/// approved Bash command at once as its own child, `/bin/zsh -c source …/shell-snapshots/… <cmd>`
/// (measured on 2.1.312), and that child appearing is the earliest sign the request is settled.
enum ClaudeCodeProcesses {
    static func children(of pid: Int32) -> [ClaudeCodeChildProcess] {
        var pids = [Int32](repeating: 0, count: 512)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listchildpids(pid, buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return [] }
        return pids.prefix(min(Int(count), pids.count)).filter { $0 > 0 }.map {
            ClaudeCodeChildProcess(pid: $0, arguments: arguments(of: $0) ?? "")
        }
    }

    /// From KERN_PROCARGS2: argc, the executable path, padding, then the NUL-separated arguments.
    static func arguments(of pid: Int32) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var fields = buffer[MemoryLayout<Int32>.size..<size].split(separator: 0, omittingEmptySubsequences: true)
        guard !fields.isEmpty else { return nil }
        fields.removeFirst()  // the executable path
        return fields.prefix(argc).map { String(decoding: $0, as: UTF8.self) }.joined(separator: " ")
    }

    /// Whether `process` is the shell the CLI runs an approved Bash command in.
    static func isBashToolShell(_ process: ClaudeCodeChildProcess, command: String) -> Bool {
        if process.arguments.contains("/shell-snapshots/") { return true }
        // Without a snapshot the command itself is in the arguments; its first line is enough.
        let firstLine = command.split(separator: "\n").first.map(String.init) ?? command
        let probe = String(firstLine.prefix(48)).trimmingCharacters(in: .whitespaces)
        return probe.count >= 4 && process.arguments.contains(probe)
    }
}
