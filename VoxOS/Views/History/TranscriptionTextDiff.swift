import Foundation

/// Word-level comparison between the raw transcript and what AI enhancement returned, so the
/// history view can show what the model actually changed rather than two blocks of prose to
/// read side by side.
///
/// Presentation only — it never feeds back into the pipeline. Bounded on both token and byte
/// count because `difference(from:)` is quadratic in the worst case and this runs on the main
/// actor while a history row is expanding.
struct TranscriptionTextDiff: Sendable, Equatable {
    /// A stretch of text that is either untouched or part of an edit, so the view can style a
    /// whole phrase in one `Text` run instead of per word.
    struct Run: Equatable, Sendable {
        var text: String
        let changed: Bool
    }

    let original: [Run]
    let enhanced: [Run]

    var hasChanges: Bool {
        original.contains(where: \.changed) || enhanced.contains(where: \.changed)
    }

    /// Splits on words, punctuation and whitespace separately so that a changed word does not
    /// drag the spaces around it into the highlight.
    private static let tokenPattern = #"\s+|[\p{L}\p{N}_]+|[^\s\p{L}\p{N}_]"#

    /// Guards chosen so the worst case stays imperceptible; past them the diff is not useful to
    /// read anyway and the view falls back to showing the text plainly.
    private static let maximumBytes = 24_000
    private static let maximumTokens = 2_048

    static func compare(original: String, enhanced: String) -> TranscriptionTextDiff? {
        guard original != enhanced else { return nil }
        guard original.utf8.count + enhanced.utf8.count <= maximumBytes else { return nil }
        guard let expression = try? NSRegularExpression(pattern: tokenPattern) else { return nil }

        func tokens(_ text: String) -> [String] {
            expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
                .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        }

        let before = tokens(original)
        let after = tokens(enhanced)
        guard before.count + after.count <= maximumTokens else { return nil }

        var removed = Set<Int>()
        var added = Set<Int>()
        for change in after.difference(from: before) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): added.insert(offset)
            }
        }
        guard !removed.isEmpty || !added.isEmpty else { return nil }

        func runs(_ tokens: [String], changed: Set<Int>) -> [Run] {
            var result: [Run] = []
            for (index, token) in tokens.enumerated() {
                let isChanged = changed.contains(index)
                if result.last?.changed == isChanged {
                    result[result.count - 1].text += token
                } else {
                    result.append(Run(text: token, changed: isChanged))
                }
            }
            return result
        }

        return TranscriptionTextDiff(
            original: runs(before, changed: removed),
            enhanced: runs(after, changed: added)
        )
    }

    /// Number of words the enhancement introduced or altered, for the collapsed row's summary.
    /// Counts words rather than runs so "changed" means something to a reader.
    var changedWordCount: Int {
        enhanced
            .filter(\.changed)
            .reduce(into: 0) { total, run in
                total += run.text.split { $0.isWhitespace }.filter { $0.contains(where: \.isLetter) }.count
            }
    }

    /// One-line summary for the collapsed row, e.g. "12 words changed".
    var summary: String {
        changedWordCount == 1
            ? String(localized: "1 word changed")
            : String(format: String(localized: "%d words changed"), changedWordCount)
    }
}
