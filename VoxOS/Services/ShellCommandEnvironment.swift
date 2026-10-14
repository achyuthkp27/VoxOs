import Darwin
import Foundation

enum ShellCommandEnvironment {
    private static let shellPathQueue = DispatchQueue(label: "com.achyuthkp.voxos.shell.path")
    private static var cachedPreferredPATH: String?
    private static let inheritedEnvironmentKeys = [
        "HOME",
        "USER",
        "LOGNAME",
        "SHELL",
        "TMPDIR",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
    ]

    /// The PATH commands run with: what the user's own shell sets up, interactive config
    /// (`.zshrc`, `.bashrc`, fish config) included, plus the usual per-user install folders.
    /// GUI apps get a bare PATH, and installers put CLIs in different places on every Mac
    /// (`~/.local/bin` added only in `.zshrc`, Homebrew, bun, cargo…), so one source is never enough.
    static func preferredPATH(fallback: String?) -> String {
        shellPathQueue.sync {
            if let cachedPreferredPATH {
                return cachedPreferredPATH
            }

            let fallbackPATH = fallback?.isEmpty == false ? fallback! : defaultPATH
            let shell = userLoginShell()
            let interactivePATH = discoverPATHFromShell(shell: shell, arguments: ["-ilc"])
            let loginPATH = discoverPATHFromShell(shell: shell, arguments: ["-lc"])
            let merged = mergedPATH(
                discovered: [interactivePATH, loginPATH, fallbackPATH, defaultPATH],
                knownDirectories: existingKnownDirectories())
            cachedPreferredPATH = merged
            return merged
        }
    }

    /// Joins PATH strings in priority order, then appends known install folders that are still
    /// missing. Duplicates and empty entries are dropped; the first occurrence wins.
    static func mergedPATH(discovered: [String?], knownDirectories: [String]) -> String {
        var seen = Set<String>()
        var entries: [String] = []
        let candidates = discovered.compactMap { $0 }.flatMap { $0.split(separator: ":").map(String.init) }
        for entry in candidates + knownDirectories {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            entries.append(trimmed)
        }
        return entries.joined(separator: ":")
    }

    /// Where CLI installers commonly put binaries for one user; only folders that exist are added.
    private static func existingKnownDirectories() -> [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "\(home)/.bun/bin", "\(home)/.cargo/bin", "\(home)/.npm-global/bin",
            "\(home)/.volta/bin", "\(home)/.deno/bin", "\(home)/go/bin", "\(home)/bin",
        ].filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// The user's login shell from the user database (not `$SHELL`, which a GUI app may not
    /// have), falling back to zsh.
    private static func userLoginShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    static func commandEnvironment(
        inheritedEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        additionalEnvironment: [String: String] = [:]
    ) -> [String: String] {
        var environment = inheritedEnvironmentKeys.reduce(into: [String: String]()) { result, key in
            if let value = inheritedEnvironment[key], !value.isEmpty {
                result[key] = value
            }
        }

        environment["PATH"] = preferredPATH(fallback: inheritedEnvironment["PATH"])
        setDefault("HOME", NSHomeDirectory(), in: &environment)
        setDefault("USER", NSUserName(), in: &environment)
        setDefault("LOGNAME", NSUserName(), in: &environment)
        setDefault("SHELL", "/bin/zsh", in: &environment)
        setDefault("TMPDIR", NSTemporaryDirectory(), in: &environment)

        additionalEnvironment.forEach { key, value in
            environment[key] = value
        }

        return environment
    }

    private static func setDefault(_ key: String, _ value: String, in environment: inout [String: String]) {
        guard environment[key]?.isEmpty ?? true else { return }
        environment[key] = value
    }

    private static let defaultPATH = "/usr/bin:/bin:/usr/sbin:/sbin"
    /// fish keeps PATH as a list; every other shell VoxOS expects (zsh, bash, sh) has it as a string.
    private static func pathDiscoveryCommand(for shell: String) -> String {
        if shell.hasSuffix("/fish") {
            return "echo __VOXOS_PATH_START__; string join : $PATH; echo __VOXOS_PATH_END__"
        }
        return "echo __VOXOS_PATH_START__; printf '%s\\n' \"$PATH\"; echo __VOXOS_PATH_END__"
    }

    private static func discoverPATHFromShell(shell: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments + [pathDiscoveryCommand(for: shell)]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }

        let stdoutBuffer = ShellCommandDataBuffer()
        let drainGroup = DispatchGroup()
        drain(stdoutPipe.fileHandleForReading, into: stdoutBuffer, group: drainGroup)
        drain(stderrPipe.fileHandleForReading, into: nil, group: drainGroup)

        let waitResult = semaphore.wait(timeout: .now() + 3)
        if waitResult == .timedOut {
            terminate(process, semaphore: semaphore)
            _ = drainGroup.wait(timeout: .now() + 1)
            return nil
        }

        guard process.terminationStatus == 0 else {
            _ = drainGroup.wait(timeout: .now() + 1)
            return nil
        }

        _ = drainGroup.wait(timeout: .now() + 1)
        let output = stdoutBuffer.stringValue()
        let startMarker = "__VOXOS_PATH_START__"
        let endMarker = "__VOXOS_PATH_END__"

        guard let startRange = output.range(of: startMarker),
            let endRange = output.range(of: endMarker, range: startRange.upperBound..<output.endIndex)
        else {
            return nil
        }

        let pathSection = output[startRange.upperBound..<endRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return pathSection.isEmpty ? nil : pathSection
    }

    private static func drain(_ handle: FileHandle, into buffer: ShellCommandDataBuffer?, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer {
                try? handle.close()
                group.leave()
            }

            let data = handle.readDataToEndOfFile()
            buffer?.append(data)
        }
    }

    private static func terminate(_ process: Process, semaphore: DispatchSemaphore) {
        guard process.isRunning else { return }

        process.terminate()
        if semaphore.wait(timeout: .now() + 1) == .success {
            return
        }

        guard process.isRunning else { return }
        _ = kill(process.processIdentifier, SIGKILL)
        _ = semaphore.wait(timeout: .now() + 1)
    }
}

private final class ShellCommandDataBuffer {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func stringValue() -> String {
        lock.lock()
        let value = data
        lock.unlock()
        return String(data: value, encoding: .utf8) ?? ""
    }
}
