import Foundation

/// Finds words that AI enhancement keeps correcting the same way, so they can be offered as
/// dictionary entries instead of being re-corrected by a model on every recording.
///
/// The signal is already there: every enhanced transcription stores both the raw transcript and
/// the enhanced text, and `TranscriptionTextDiff` says which words changed. A substitution the
/// model makes over and over — "kubernets" to "Kubernetes" — is a vocabulary gap, and fixing it
/// in the dictionary is both faster and more reliable than asking a model to catch it each time.
///
/// Deliberately conservative. A wrong entry rewrites words silently in every future
/// transcription, so it is far better to miss a real correction than to invent one: only
/// single-word one-for-one substitutions count, and only after they recur.
enum DictionaryCorrectionLearner {

    struct Candidate: Equatable, Identifiable {
        let original: String
        let replacement: String
        let occurrences: Int

        var id: String { "\(original)\u{001F}\(replacement)" }
    }

    /// A correction has to recur before it is worth suggesting; a one-off is usually the model
    /// reading context rather than fixing a word.
    static let defaultMinimumOccurrences = 3

    /// - Parameters:
    ///   - transcriptions: raw/enhanced pairs, newest first or not — order does not matter.
    ///   - knownOriginals: originals already in the dictionary, compared case-insensitively.
    ///   - minimumOccurrences: how many times a substitution must recur to be suggested.
    static func candidates(
        from transcriptions: [(original: String, enhanced: String)],
        knownOriginals: Set<String> = [],
        minimumOccurrences: Int = defaultMinimumOccurrences
    ) -> [Candidate] {
        let known = Set(knownOriginals.map { $0.lowercased() })
        var counts: [Pair: Int] = [:]

        for entry in transcriptions {
            for pair in substitutions(original: entry.original, enhanced: entry.enhanced) {
                guard !known.contains(pair.original.lowercased()) else { continue }
                counts[pair, default: 0] += 1
            }
        }

        return
            counts
            .filter { $0.value >= minimumOccurrences }
            .map { Candidate(original: $0.key.original, replacement: $0.key.replacement, occurrences: $0.value) }
            // Most-corrected first; ties alphabetical so the list does not reshuffle between runs.
            .sorted { ($0.occurrences, $1.original) > ($1.occurrences, $0.original) }
    }

    private struct Pair: Hashable {
        let original: String
        let replacement: String
    }

    /// One-for-one word substitutions between the two texts.
    ///
    /// Changed runs alternate with unchanged ones, so the k-th changed run on each side describes
    /// the same edit. That only holds when both sides changed the same number of times; when they
    /// do not, the texts diverged structurally (a sentence rewritten, not a word fixed) and there
    /// is nothing safe to infer.
    private static func substitutions(original: String, enhanced: String) -> [Pair] {
        guard let diff = TranscriptionTextDiff.compare(original: original, enhanced: enhanced) else {
            return []
        }

        let removed = diff.original.filter(\.changed)
        let added = diff.enhanced.filter(\.changed)
        guard removed.count == added.count else { return [] }

        return zip(removed, added).compactMap { before, after in
            guard let from = singleWord(in: before.text), let to = singleWord(in: after.text) else {
                return nil
            }
            // Case and punctuation fixes are the model doing grammar, not learning a word.
            guard from.lowercased() != to.lowercased() else { return nil }
            return Pair(original: from, replacement: to)
        }
    }

    /// The run's only word, or nil if it holds none or several. Multi-word runs are phrase edits
    /// rather than misheard words, and a dictionary entry cannot represent them faithfully.
    ///
    /// The diff already splits on punctuation, so a hyphenated term arrives here in parts and is
    /// learned per part. Apostrophes and hyphens are still tolerated so this stays correct if the
    /// tokenisation is ever widened.
    private static func singleWord(in text: String) -> String? {
        let words = text.split { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "-" }
        guard words.count == 1 else { return nil }
        let word = String(words[0])
        // Needs a letter: pure numbers are values, not vocabulary.
        guard word.contains(where: \.isLetter) else { return nil }
        return word
    }
}
