import Combine
import Foundation

/// The user's Shortcuts on the Sound page, each run with a click, through macOS's own
/// `shortcuts` command. The list is read when the section opens, never in the background.
@MainActor
final class NotchShortcuts: ObservableObject {
    static let shared = NotchShortcuts()

    static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")

    @Published private(set) var names: [String] = []
    /// The shortcut running now, by name.
    @Published private(set) var running: String?

    private init() {}

    func reload() {
        Task { @MainActor [weak self] in
            let output = await Self.run(["list"])
            self?.names = Self.names(from: output ?? "")
        }
    }

    func run(_ name: String) {
        guard running == nil else { return }
        running = name
        ActivityTrail.mark("notch shortcut run")
        Task { @MainActor [weak self] in
            _ = await Self.run(["run", name])
            self?.running = nil
        }
    }

    nonisolated static func names(from list: String) -> [String] {
        list.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private nonisolated static func run(_ arguments: [String]) async -> String? {
        await Task.detached(priority: .userInitiated) { () -> String? in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = tool
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}
