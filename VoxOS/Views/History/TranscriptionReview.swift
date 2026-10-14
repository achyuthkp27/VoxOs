import Foundation

/// Finds the words that were heard one way and meant another, by lining up what the
/// recogniser wrote against a corrected version (the AI-cleaned text, or the user's own edit).
///
/// Only word changes count: punctuation, capitalisation and added or dropped words are how
/// cleanup tidies text, not mishearings, and offering them would bury the real ones.
enum TranscriptionReview {
    struct Correction: Hashable, Identifiable {
        let heard: String
        let written: String

        var id: String { heard.lowercased() + "\u{1F}" + written.lowercased() }
    }

    /// A correction spanning more words than this is a rewrite, not a mishearing.
    static let maxWordsPerSide = 4
    /// Longer texts are not lined up word by word; the comparison is quadratic.
    static let maxWords = 600

    static func corrections(heard: String, written: String) -> [Correction] {
        let a = words(in: heard)
        let b = words(in: written)
        guard !a.isEmpty, !b.isEmpty, a.count <= maxWords, b.count <= maxWords else { return [] }

        // Longest common subsequence over case-folded words.
        let aKeys = a.map(key)
        let bKeys = b.map(key)
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] =
                    aKeys[i] == bKeys[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var corrections: [Correction] = []
        var seen = Set<String>()
        var i = 0
        var j = 0
        var heardRun: [String] = []
        var writtenRun: [String] = []

        func flush() {
            defer {
                heardRun.removeAll()
                writtenRun.removeAll()
            }
            guard !heardRun.isEmpty, !writtenRun.isEmpty,
                heardRun.count <= maxWordsPerSide, writtenRun.count <= maxWordsPerSide
            else { return }
            let correction = Correction(
                heard: heardRun.joined(separator: " "), written: writtenRun.joined(separator: " "))
            guard key(correction.heard) != key(correction.written), seen.insert(correction.id).inserted else { return }
            corrections.append(correction)
        }

        while i < a.count || j < b.count {
            if i < a.count, j < b.count, aKeys[i] == bKeys[j] {
                flush()
                i += 1
                j += 1
            } else if j < b.count, i == a.count || table[i][j + 1] >= table[i + 1][j] {
                writtenRun.append(b[j])
                j += 1
            } else {
                heardRun.append(a[i])
                i += 1
            }
        }
        flush()
        return corrections
    }

    private static func words(in text: String) -> [String] {
        let pattern = #"[\p{L}\p{N}][\p{L}\p{N}'’.\-]*[\p{L}\p{N}]|[\p{L}\p{N}]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func key(_ word: String) -> String {
        word.lowercased().replacingOccurrences(of: "’", with: "'")
    }
}
