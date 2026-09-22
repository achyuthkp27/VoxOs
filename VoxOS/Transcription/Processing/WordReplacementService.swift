import Foundation
import SwiftData

class WordReplacementService {
    static let shared = WordReplacementService()

    private init() {}

    func applyReplacements(to text: String, using context: ModelContext) -> String {
        let descriptor = FetchDescriptor<WordReplacement>(
            predicate: #Predicate { $0.isEnabled }
        )

        guard let replacements = try? context.fetch(descriptor), !replacements.isEmpty else {
            return text  // No replacements to apply
        }

        // One pass over the *original* text. Rules used to be applied one after another to an
        // accumulating string, so every rule rescanned the output of the rules before it:
        // `a -> b` plus `b -> c` turned "a" into "c", and a replacement that contained another
        // trigger got rewritten again. Now each character of the input is claimed by at most
        // one rule, longest trigger first, and the replacements are spliced in at the end.
        struct Rule {
            let trigger: String
            let replacement: String
        }

        let rules =
            replacements
            .flatMap { replacement -> [Rule] in
                replacement.originalText
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .map { Rule(trigger: $0, replacement: replacement.replacementText) }
            }
            // Longest-first so specific triggers match before shorter overlapping ones.
            .sorted { $0.trigger.count > $1.trigger.count }

        let nsText = text as NSString
        var claimed: [NSRange] = []
        var edits: [(range: NSRange, replacement: String)] = []

        for rule in rules {
            let matches = matchRanges(of: rule.trigger, in: nsText)
            for range in matches where !claimed.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                claimed.append(range)
                edits.append((range, rule.replacement))
            }
        }

        guard !edits.isEmpty else { return text }

        let result = NSMutableString(string: text)
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            result.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return result as String
    }

    /// Case-insensitive matches of `trigger`, as ranges into `text`.
    private func matchRanges(of trigger: String, in text: NSString) -> [NSRange] {
        let fullRange = NSRange(location: 0, length: text.length)

        guard usesWordBoundaries(for: trigger) else {
            // Fallback substring search for non-spaced scripts.
            var ranges: [NSRange] = []
            var searchRange = fullRange
            while searchRange.length > 0 {
                let found = text.range(of: trigger, options: .caseInsensitive, range: searchRange)
                guard found.location != NSNotFound else { break }
                ranges.append(found)
                let next = found.location + max(found.length, 1)
                searchRange = NSRange(location: next, length: text.length - next)
            }
            return ranges
        }

        // Lookarounds instead of \b so punctuation acts as a word boundary.
        // Word chars are Unicode letters/marks/digits (not just ASCII) so triggers
        // can't match inside words like "vergrößern"; non-spaced scripts are exempt
        // so Latin triggers flush against CJK/Thai still match (mirrors usesWordBoundaries).
        let escaped = NSRegularExpression.escapedPattern(for: trigger)
        // scx (Script_Extensions) so shared marks like the prolonged sound mark
        // U+30FC (Script=Common, scx=Hira Kana) stay exempt too.
        let wordChar =
            "[[\\p{L}\\p{M}\\p{N}]-[\\p{scx=Han}\\p{scx=Hiragana}\\p{scx=Katakana}\\p{scx=Hangul}\\p{scx=Thai}]]"
        let pattern = "(?<!\(wordChar))\(escaped)(?!\(wordChar))"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }
        // Ranges are spliced in verbatim, never through a regex template, so `$` and `\` in a
        // replacement (prices, paths) come out exactly as the user typed them.
        return regex.matches(in: text as String, options: [], range: fullRange).map(\.range)
    }

    private func usesWordBoundaries(for text: String) -> Bool {
        // Returns false for languages without spaces (CJK, Thai), true for spaced languages
        let nonSpacedScripts: [ClosedRange<UInt32>] = [
            0x3040...0x309F,  // Hiragana
            0x30A0...0x30FF,  // Katakana
            0x4E00...0x9FFF,  // CJK Unified Ideographs
            0xAC00...0xD7AF,  // Hangul Syllables
            0x0E00...0x0E7F,  // Thai
        ]

        for scalar in text.unicodeScalars {
            for range in nonSpacedScripts {
                if range.contains(scalar.value) {
                    return false
                }
            }
        }

        return true
    }
}
