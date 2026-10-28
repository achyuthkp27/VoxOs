import AVFoundation

/// Reads Claude's reply aloud in the system voice, without the markdown's marks.
@MainActor
enum ClaudeCodeSpeech {
    private static let synthesizer = AVSpeechSynthesizer()

    static func speak(_ text: String) {
        stop()
        let utterance = AVSpeechUtterance(string: spoken(text))
        synthesizer.speak(utterance)
    }

    static func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    /// Code fences, emphasis, headings and list marks are for the eye; links read as their text.
    nonisolated static func spoken(_ markdown: String) -> String {
        var text = markdown.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "(?m)^\\s*(#+|[-*+]|\\d+\\.)\\s+", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "[*_`]", with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
