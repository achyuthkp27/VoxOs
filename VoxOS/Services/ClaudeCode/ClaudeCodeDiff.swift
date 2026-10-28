import Foundation

/// What an Edit, MultiEdit or Write would change, for the approval card: removed lines, then
/// added ones, without the lines both sides share at the start and end, so the change shows
/// first. Not a full diff: the card has room for a few lines, and a request is about one change.
enum ClaudeCodeDiff {
    struct Line: Equatable {
        enum Kind: Equatable {
            case removed
            case added
            /// A gap between edits, or the count of lines not shown.
            case note
        }

        let kind: Kind
        let text: String

        var marker: String {
            switch kind {
            case .removed: return "-"
            case .added: return "+"
            case .note: return " "
            }
        }
    }

    /// The card scrolls through at most this many.
    static let maxLines = 60
    /// About what fits on one line of the card in its mono type; a pair of lines that differ past
    /// this is shown from a little before the difference.
    static let visibleColumns = 58
    /// How much of a long line's start names it, and how much of what it shares is kept before
    /// the difference.
    static let headColumns = 26
    static let leadIn = 12

    static func lines(toolName: String, input: [String: Any]) -> [Line]? {
        var lines: [Line]
        switch toolName {
        case "Edit":
            lines = edit(old: input["old_string"] as? String ?? "", new: input["new_string"] as? String ?? "")
        case "MultiEdit":
            let edits = (input["edits"] as? [[String: Any]] ?? []).map {
                edit(old: $0["old_string"] as? String ?? "", new: $0["new_string"] as? String ?? "")
            }
            lines = edits.filter { !$0.isEmpty }.enumerated().flatMap { index, edit in
                index == 0 ? edit : [Line(kind: .note, text: "…")] + edit
            }
        case "Write":
            lines = split(input["content"] as? String ?? "").map { Line(kind: .added, text: $0) }
        default:
            return nil
        }
        guard !lines.isEmpty else { return nil }
        if lines.count > maxLines {
            let hidden = lines.count - maxLines
            lines =
                Array(lines.prefix(maxLines)) + [Line(kind: .note, text: String(localized: "… \(hidden) more lines"))]
        }
        return lines
    }

    static func edit(old: String, new: String) -> [Line] {
        var removed = split(old)
        var added = split(new)
        while let first = removed.first, first == added.first {
            removed.removeFirst()
            added.removeFirst()
        }
        while let last = removed.last, last == added.last {
            removed.removeLast()
            added.removeLast()
        }
        // Indentation every line shares says nothing about the change.
        let indent =
            (removed + added).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix(while: { $0 == " " }).count }.min() ?? 0
        removed = removed.map { String($0.dropFirst(min(indent, $0.prefix(while: { $0 == " " }).count))) }
        added = added.map { String($0.dropFirst(min(indent, $0.prefix(while: { $0 == " " }).count))) }
        // A line changed in place: both versions start from just before where they differ.
        if removed.count == added.count {
            for index in removed.indices {
                (removed[index], added[index]) = focused(removed[index], added[index])
            }
        }
        return removed.map { Line(kind: .removed, text: $0) } + added.map { Line(kind: .added, text: $0) }
    }

    /// The two versions of one line, when their first difference would be past the edge of the
    /// card: the start of the line up to a word break (what the line is), then from a little
    /// before the difference (what changed).
    static func focused(_ old: String, _ new: String) -> (String, String) {
        let shared = zip(old, new).prefix(while: { $0 == $1 }).count
        guard max(old.count, new.count) > visibleColumns, shared > visibleColumns - 12 else {
            return (old, new)
        }
        let start = old.prefix(headColumns)
        let head = start.lastIndex(of: " ").map { String(start[..<$0]) } ?? String(start)
        // The kept part starts at a word, a little before the difference.
        let before = old.prefix(max(0, shared - leadIn))
        let word = before.lastIndex(of: " ").map { before.distance(from: before.startIndex, to: $0) + 1 }
        let cut = max(head.count, word ?? before.count)
        return (head + " … " + old.dropFirst(cut), head + " … " + new.dropFirst(cut))
    }

    /// Lines without a trailing empty one, tabs as spaces so mono columns line up.
    private static func split(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var lines = text.replacingOccurrences(of: "\t", with: "    ").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }
}
