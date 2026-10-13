import Foundation

struct TranscriptionOutputFilter {
    // Non-speech markers Whisper-style models emit for silence, music and noise. Only these are
    // stripped: a catch-all `\([^)]{0,40}\)` also deleted real parentheticals the user dictated,
    // such as "(555) 123-4567" or "(see appendix)".
    private static let nonSpeechMarkers = [
        "music", "applause", "laughs", "laughter", "laughing", "chuckles", "giggles",
        "inaudible", "unintelligible", "indistinct", "silence", "blank_audio", "blank audio",
        "noise", "static", "crosstalk", "pause", "sighs", "coughs", "coughing", "sneezes",
        "clears throat", "breathing", "humming", "singing", "beep", "clicking", "typing",
        "speaking in foreign language", "foreign language", "no audio", "no speech", "sfx",
    ]

    // One bracketed marker: optional short qualifier words around the keyword ("[upbeat music]",
    // "(music playing)", "[ Silence ]", "[BLANK_AUDIO]"), case-insensitive, never across lines.
    private static let nonSpeechMarkerPattern: String = {
        let keywords = nonSpeechMarkers.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        let qualifier = #"(?:[a-z_-]+ ){0,3}"#
        let trailing = #"(?: [a-z0-9:_-]+){0,3}"#
        return #"[\[\(\{]\s*"# + qualifier + #"(?:"# + keywords + #")"# + trailing + #"\s*[\]\)\}]"#
    }()

    /// Removes known non-speech markers such as "[Music]" or "(laughs)" and nothing else.
    static func removeNonSpeechMarkers(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: nonSpeechMarkerPattern, options: .caseInsensitive)
        else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    static func filter(_ text: String) -> String {
        var filteredText = text

        // Remove <TAG>...</TAG> blocks
        let tagBlockPattern = #"<([A-Za-z][A-Za-z0-9:_-]*)[^>]*>[\s\S]*?</\1>"#
        if let regex = try? NSRegularExpression(pattern: tagBlockPattern) {
            let range = NSRange(filteredText.startIndex..., in: filteredText)
            filteredText = regex.stringByReplacingMatches(in: filteredText, options: [], range: range, withTemplate: "")
        }

        filteredText = removeNonSpeechMarkers(filteredText)

        // Remove configured filler words. An empty list is naturally a no-op.
        for fillerWord in FillerWordManager.shared.fillerWords {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: fillerWord))\\b[,.]?"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                let range = NSRange(filteredText.startIndex..., in: filteredText)
                filteredText = regex.stringByReplacingMatches(
                    in: filteredText, options: [], range: range, withTemplate: "")
            }
        }

        // Clean whitespace
        filteredText = filteredText.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        filteredText = filteredText.trimmingCharacters(in: .whitespacesAndNewlines)

        return filteredText
    }
}
