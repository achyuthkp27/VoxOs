import Foundation

/// A script for the prompter: its words in order, split into paragraphs, with the text in square
/// brackets kept as presenter notes ("[pause]", "[smile]") that are shown but never listened for.
struct PrompterScript: Equatable {
    struct Word: Equatable {
        /// As written, with its punctuation.
        let text: String
        /// Lowercased, without punctuation or accents: what speech is matched against. Empty for a
        /// note, or for a word that is only punctuation.
        let spoken: String
        let isNote: Bool
        let paragraph: Int
    }

    let words: [Word]
    /// For each word that can be spoken, its index in `words`, in order.
    let spokenIndices: [Int]
    /// The spoken form of those words, in the same order.
    let spokenWords: [String]

    init(_ text: String) {
        var words: [Word] = []
        var paragraph = 0
        var inNote = false
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if index > 0, words.last?.paragraph == paragraph { paragraph += 1 }
                continue
            }
            for token in trimmed.split(whereSeparator: \.isWhitespace).map(String.init) {
                let opens = token.hasPrefix("[")
                let closes = token.hasSuffix("]")
                let note = inNote || opens
                if opens, !closes { inNote = true }
                if inNote, closes { inNote = false }
                words.append(
                    Word(
                        text: token, spoken: note ? "" : Self.normalize(token), isNote: note,
                        paragraph: paragraph))
            }
            // A line break inside a paragraph is kept as a space, as a teleprompter flows text.
        }
        self.words = words
        spokenIndices = words.indices.filter { !words[$0].spoken.isEmpty }
        spokenWords = spokenIndices.map { words[$0].spoken }
    }

    var paragraphCount: Int { (words.last?.paragraph ?? -1) + 1 }

    /// The index in `words` of the spoken word at `position`, or one past the end.
    func wordIndex(atSpoken position: Int) -> Int {
        position < spokenIndices.count ? spokenIndices[position] : words.count
    }

    /// The spoken position of the word at `index` in `words`, or of the next spoken word after a note.
    func spokenPosition(ofWord index: Int) -> Int {
        spokenIndices.firstIndex { $0 >= index } ?? spokenIndices.count
    }

    /// Lowercased, accents and punctuation removed, small numbers written as words, so "Twenty-one,"
    /// and what the recogniser hears as "21" both come out as "twentyone".
    static func normalize(_ token: String) -> String {
        let folded = token.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let kept = String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        if let number = Int(kept), let word = numberWords[number] { return word }
        return kept
    }

    private static let numberWords: [Int: String] = {
        let ones = [
            "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
            "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
        ]
        let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
        var map: [Int: String] = [:]
        for number in 0..<100 {
            map[number] = number < 20 ? ones[number] : tens[number / 10] + (number % 10 == 0 ? "" : ones[number % 10])
        }
        return map
    }()
}

/// Finds where in the script the speaker is, from the last few words heard.
///
/// The last words heard are matched against the script around the current place, a little behind
/// and further ahead, so the place follows a skipped sentence and a repeated one, and stays put
/// through an ad-lib that matches nothing. Moving back needs a stronger match than moving on, so a
/// recogniser revising its guess does not make the text jump.
enum PrompterAligner {
    /// How many of the last words heard are matched.
    static let tailLength = 8
    /// How far behind and ahead of the current place a match is looked for, in words.
    static let lookBehind = 40
    static let lookAhead = 60

    /// The new place: the spoken position of the next word to say.
    static func advance(from cursor: Int, script: [String], heard: [String]) -> Int {
        let tail = Array(heard.suffix(tailLength)).filter { !$0.isEmpty }
        guard !tail.isEmpty, !script.isEmpty else { return cursor }
        let low = max(0, cursor - lookBehind)
        let high = min(script.count - 1, cursor + lookAhead)
        guard low <= high else { return cursor }

        var best: (end: Int, score: Double)?
        for end in low...high {
            let matched = score(tail: tail, script: script, end: end)
            guard matched > 0 else { continue }
            let distance = end + 1 - cursor
            // A jump back must be clearly what was said; so must a long jump ahead.
            if distance < 0, matched < 3 { continue }
            if distance > 12, matched < 3 { continue }
            if matched < 2 {
                // One word alone moves on only to a nearby, distinctive word.
                guard distance >= 0, distance <= 3, script[end].count >= 3 else { continue }
            }
            // Prefer the stronger match, then the one nearer to where the speaker was.
            let weighted = Double(matched) - Double(abs(distance)) * 0.01
            if best == nil || weighted > best!.score { best = (end, weighted) }
        }
        return best.map { $0.end + 1 } ?? cursor
    }

    /// How many of the tail's words match the script up to and including `end`, in order, with
    /// the script's word at `end` matched by one of the last two words heard.
    static func score(tail: [String], script: [String], end: Int) -> Int {
        let window = Array(script[max(0, end - tail.count - 3)...end])
        // The last script word must be what was just said (or the word before it).
        let lastHeard = tail.count - 1
        guard similar(window.last!, tail[lastHeard]) || (lastHeard > 0 && similar(window.last!, tail[lastHeard - 1]))
        else { return 0 }
        // Longest common subsequence, words compared loosely.
        var previous = [Int](repeating: 0, count: window.count + 1)
        for heardWord in tail {
            var current = [Int](repeating: 0, count: window.count + 1)
            for (index, scriptWord) in window.enumerated() {
                current[index + 1] =
                    similar(heardWord, scriptWord)
                    ? previous[index] + 1 : max(previous[index + 1], current[index])
            }
            previous = current
        }
        return previous[window.count]
    }

    /// The same word, allowing a letter or two of difference in longer words: recognisers often
    /// get an ending or a plural wrong.
    static func similar(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let shorter = min(lhs.count, rhs.count)
        guard shorter >= 4 else { return false }
        let allowed = shorter >= 7 ? 2 : 1
        guard abs(lhs.count - rhs.count) <= allowed else { return false }
        return editDistance(lhs, rhs, limit: allowed) <= allowed
    }

    static func editDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var next = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                next[j] = min(row[j] + 1, next[j - 1] + 1, row[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            if next.min()! > limit { return limit + 1 }
            row = next
        }
        return row[b.count]
    }
}
