import Foundation

/// Turns timed tokens plus speaker time ranges into a transcript that says who said what.
///
/// Diarization answers "who spoke when" and transcription answers "what was said"; neither knows
/// about the other. Joining them is just interval overlap, but the details decide whether the
/// result reads like a conversation or like noise — which is why this is a plain value type with
/// tests rather than something buried in the transcription pipeline.
enum SpeakerAttribution {

    /// A stretch of transcript attributed to one speaker.
    struct Turn: Equatable {
        let speakerId: String
        let text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    /// A token with the time range it was spoken over. Mirrors FluidAudio's `TokenTiming` without
    /// depending on it, so this stays testable and independent of the ASR backend.
    struct TimedToken: Equatable {
        let text: String
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    /// A speaker's turn on the audio timeline.
    struct SpeakerRange: Equatable {
        let speakerId: String
        let startTime: TimeInterval
        let endTime: TimeInterval
    }

    /// Assigns each token to the speaker whose range it overlaps most, then merges consecutive
    /// tokens from the same speaker into turns.
    ///
    /// Overlap rather than midpoint: a token straddling a speaker change belongs to whoever was
    /// speaking for most of it, and midpoint gets that wrong exactly at the handover, which is
    /// where errors are most visible.
    static func turns(tokens: [TimedToken], speakers: [SpeakerRange]) -> [Turn] {
        guard !tokens.isEmpty, !speakers.isEmpty else { return [] }

        var turns: [Turn] = []
        // Which range each token landed in. The diarizer has already decided where one turn ends
        // and the next begins, so two utterances by the same person either side of a pause stay
        // separate lines — merging on speaker id alone would put a question and an answer nine
        // seconds apart on one line, and no gap threshold of ours would beat the segmentation.
        var lastRangeIndex: Int?

        for token in tokens {
            let piece = token.text.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { continue }
            guard let match = speaker(for: token, in: speakers) else { continue }
            let speakerId = speakers[match].speakerId
            defer { lastRangeIndex = match }

            if var last = turns.last, last.speakerId == speakerId, lastRangeIndex == match {
                // Tokens carry their own leading spaces in most tokenisers; joining on a single
                // space and trimming keeps spacing sane whichever convention the model uses.
                last = Turn(
                    speakerId: speakerId,
                    text: last.text + separator(before: token.text) + piece,
                    startTime: last.startTime,
                    endTime: token.endTime)
                turns[turns.count - 1] = last
            } else {
                turns.append(
                    Turn(
                        speakerId: speakerId, text: piece,
                        startTime: token.startTime, endTime: token.endTime))
            }
        }
        return turns
    }

    /// Punctuation attaches to the word before it; anything else gets a space.
    private static func separator(before token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "" }
        let attaches: Set<Character> = [".", ",", "!", "?", ";", ":", ")", "]", "'", "’", "”", "%"]
        return attaches.contains(first) ? "" : " "
    }

    /// Index of the range sharing the most time with this token, or nil when none overlaps it.
    ///
    /// A token outside every range is dropped rather than guessed at: diarization leaves gaps for
    /// silence and non-speech, and inventing an attribution there would put words in someone's
    /// mouth.
    private static func speaker(for token: TimedToken, in speakers: [SpeakerRange]) -> Int? {
        var best: (index: Int, overlap: TimeInterval)?
        for (index, range) in speakers.enumerated() {
            let overlap = min(token.endTime, range.endTime) - max(token.startTime, range.startTime)
            guard overlap > 0 else { continue }
            if best == nil || overlap > best!.overlap {
                best = (index, overlap)
            }
        }
        return best?.index
    }

    /// Renders turns as a transcript, one labelled line per turn.
    ///
    /// `names` maps a diarizer speaker id to something a person chose; anything unmapped falls
    /// back to a stable "Speaker 1" style label derived from order of first appearance, so the
    /// numbering does not jump around between runs.
    static func transcript(_ turns: [Turn], names: [String: String] = [:]) -> String {
        var order: [String: Int] = [:]
        for turn in turns where order[turn.speakerId] == nil {
            order[turn.speakerId] = order.count + 1
        }
        return
            turns
            .map { turn in
                let label =
                    names[turn.speakerId]
                    ?? String(format: String(localized: "Speaker %d"), order[turn.speakerId] ?? 1)
                return "\(label): \(turn.text)"
            }
            .joined(separator: "\n")
    }
}
