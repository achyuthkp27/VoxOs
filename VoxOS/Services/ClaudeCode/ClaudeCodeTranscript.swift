import Foundation

/// What a session's transcript says that its hooks do not: the session's title, the git branch
/// it runs on, and an Esc that ended a turn.
///
/// The transcript is the CLI's own JSONL log of the session (measured on 2.1.312):
/// - every message line carries `gitBranch` ("HEAD" when detached);
/// - `{"type":"ai-title","aiTitle":…}` names the session, and `{"type":"custom-title",
///   "customTitle":…}` does after a /rename; both are appended again later and the newest wins;
/// - Esc writes a user message whose text starts "[Request interrupted by user".
enum ClaudeCodeTranscript {
    struct Info: Equatable {
        var title: String?
        var branch: String?
    }

    /// Titles and branches are repeated as the session goes on, so the end of the file usually
    /// has both; a title written only near the start of a long session is found in the head.
    static let tailBytes = 256 * 1024
    static let headBytes = 64 * 1024

    static func info(at path: String) -> Info {
        guard let handle = FileHandle(forReadingAtPath: path) else { return Info() }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        handle.seek(toFileOffset: start)
        var found = Self.info(inLines: lines(of: handle.readDataToEndOfFile(), cutFirst: start > 0))
        if found.title == nil, start > 0 {
            handle.seek(toFileOffset: 0)
            let head = Self.info(inLines: lines(of: handle.readData(ofLength: headBytes), cutFirst: false))
            found.title = head.title
            if found.branch == nil { found.branch = head.branch }
        }
        return found
    }

    /// A read that starts mid-file starts mid-line; that first piece is dropped.
    private static func lines(of data: Data, cutFirst: Bool) -> [Substring] {
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        return cutFirst ? Array(lines.dropFirst()) : lines
    }

    /// The newest title (a /rename over the generated one) and the newest branch.
    static func info(inLines lines: [Substring]) -> Info {
        var info = Info()
        var aiTitle: String?
        for line in lines.reversed() {
            if info.branch == nil, let branch = value(of: "gitBranch", in: line), !branch.isEmpty {
                info.branch = branch
            }
            if info.title == nil, line.contains(#""type":"custom-title""#) {
                info.title = value(of: "customTitle", in: line)
            }
            if aiTitle == nil, line.contains(#""type":"ai-title""#) {
                aiTitle = value(of: "aiTitle", in: line)
            }
            if info.title != nil, info.branch != nil { break }
        }
        if info.title == nil { info.title = aiTitle }
        return info
    }

    /// One string field of a JSON line. Lines can be long (a tool's whole output), so only one
    /// that holds the key is parsed.
    private static func value(of key: String, in line: Substring) -> String? {
        guard line.contains("\"\(key)\""),
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            let value = object[key] as? String
        else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func isInterrupt(_ line: Substring) -> Bool {
        line.contains(#""type":"user""#) && line.contains("[Request interrupted by user")
    }
}

/// Follows a transcript as the CLI appends to it, for an Esc that ends a turn: the CLI sends no
/// hook for that, only an idle notification a minute later. The kernel says when the file grows
/// and only the new bytes are read, so nothing runs while the session is quiet.
final class ClaudeCodeTranscriptWatch: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.achyuthkp.voxos.claude-code-transcript")
    private let handle: FileHandle
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64
    private var partial = Data()

    init?(path: String, onInterrupt: @escaping @Sendable () -> Void) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        self.handle = handle
        // What is already written is history.
        offset = handle.seekToEndOfFile()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor, eventMask: [.extend, .write], queue: queue)
        source.setEventHandler { [weak self] in
            if self?.readNew() == true { onInterrupt() }
        }
        source.setCancelHandler { try? handle.close() }
        source.resume()
        self.source = source
    }

    func cancel() {
        source?.cancel()
        source = nil
    }

    deinit { source?.cancel() }

    /// Whether the new lines hold an interrupt. A line still being written waits for its end.
    private func readNew() -> Bool {
        let size = handle.seekToEndOfFile()
        if size < offset { offset = size }
        handle.seek(toFileOffset: offset)
        let data = handle.readDataToEndOfFile()
        offset += UInt64(data.count)
        partial.append(data)
        guard let newline = partial.lastIndex(of: 0x0A) else { return false }
        let complete = String(decoding: partial[partial.startIndex..<newline], as: UTF8.self)
        partial = Data(partial[partial.index(after: newline)...])
        return complete.split(separator: "\n").contains(where: ClaudeCodeTranscript.isInterrupt)
    }
}
