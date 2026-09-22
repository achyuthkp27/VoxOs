import AppKit
import Foundation
import os

/// Reads the selection from terminals that expose it through their own tooling rather than
/// through Accessibility. cmux (Ghostty-based) answers none of the general routes: its text
/// surface has no AX selection, its Copy menu item reports no enabled state, and it ignores a
/// synthesised ⌘C. It does ship a command-line tool that talks to the running app over a Unix
/// socket, and `read-selection` returns the current selection verbatim.
enum TerminalSelectionReader {
    private static let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "TerminalSelectionReader")
    private static let cmuxBundleID = "com.cmuxterm.app"
    private static let timeout: TimeInterval = 2

    /// The selection in the frontmost app, when that app is a supported terminal; nil otherwise
    /// or when nothing is selected.
    @MainActor
    static func selectionInFrontmostTerminal() async -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == cmuxBundleID,
            let bundleURL = app.bundleURL
        else { return nil }

        let tool = bundleURL.appendingPathComponent("Contents/Resources/bin/cmux")
        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            logger.notice("cmux CLI not found at \(tool.path, privacy: .public)")
            return nil
        }

        let output = await mcpRace(seconds: timeout) {
            await Task.detached(priority: .userInitiated) { run(tool, arguments: ["read-selection"]) }.value
        }
        guard let output, let output else {
            logger.notice("cmux read-selection produced no output")
            return nil
        }
        return parseCmuxSelection(output)
    }

    /// `read-selection` prints a `Kind:` header, a blank line, then either the selection or
    /// `Has selection: false`.
    static func parseCmuxSelection(_ output: String) -> String? {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let first = lines.first, first.hasPrefix("Kind:") || first.isEmpty {
            lines.removeFirst()
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty, !body.hasPrefix("Has selection: false") else { return nil }
        return body
    }

    private static func run(_ tool: URL, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            logger.error("cmux CLI failed to launch: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            logger.notice("cmux read-selection exited with \(process.terminationStatus, privacy: .public)")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
