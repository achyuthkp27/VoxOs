import Testing

@testable import VoxOS

/// The agreement engine confirms at sentence boundaries, and otherwise once the unconfirmed
/// window grows past `maxUnconfirmedSeconds`, so the audio buffer stays bounded.
struct WordAgreementEngineTests {
    /// One unpunctuated word per second, starting at `start`.
    private func words(count: Int, start: Double = 0) -> [TimedWord] {
        (0..<count).map { i in
            let t = start + Double(i)
            return TimedWord(text: "w\(i)", startTime: t, endTime: t + 1, confidence: 0.9)
        }
    }

    @Test func forceConfirmsOldWordsWhenWindowExceedsBound() {
        var config = AgreementConfig()
        config.maxUnconfirmedSeconds = 30
        config.forcedConfirmKeepSeconds = 10
        let engine = WordAgreementEngine(config: config)
        let pass = words(count: 40)  // 0 s ... 40 s, no sentence enders

        var confirmed = ""
        for _ in 0..<config.tokenConfirmationsNeeded + 1 {
            confirmed = engine.processTranscriptionResult(words: pass).newlyConfirmedText
        }

        // Everything that ended at or before 40 s - 10 s is confirmed; the last 10 s stay hypothesis.
        #expect(confirmed == (0..<30).map { "w\($0)" }.joined(separator: " "))
        #expect(engine.confirmedEndTime == 30)
        #expect(engine.hypothesisStartTime == 30)
    }

    @Test func doesNotForceConfirmInsideTheBound() {
        let engine = WordAgreementEngine()
        let pass = words(count: 20)  // 20 s window, under the 30 s default

        for _ in 0..<6 {
            #expect(engine.processTranscriptionResult(words: pass).newlyConfirmedText.isEmpty)
        }
        #expect(engine.confirmedText.isEmpty)
    }

    @Test func forcedCutIgnoresBoundaryConfidenceGate() {
        var config = AgreementConfig()
        config.maxUnconfirmedSeconds = 30
        config.forcedConfirmKeepSeconds = 10
        let engine = WordAgreementEngine(config: config)
        var pass = words(count: 40)
        pass[29] = TimedWord(text: "w29", startTime: 29, endTime: 30, confidence: 0.1)

        var confirmed = ""
        for _ in 0..<config.tokenConfirmationsNeeded + 1 {
            confirmed = engine.processTranscriptionResult(words: pass).newlyConfirmedText
        }
        #expect(confirmed.hasSuffix("w29"))
    }

    @Test func punctuationRuleStillConfirmsShortWindows() {
        let engine = WordAgreementEngine()
        let texts = "one two three. four five six. seven eight nine. ten eleven.".split(separator: " ")
        let pass = texts.enumerated().map { i, text in
            TimedWord(text: String(text), startTime: Double(i), endTime: Double(i) + 1, confidence: 0.9)
        }

        var confirmed = ""
        for _ in 0..<4 {
            confirmed = engine.processTranscriptionResult(words: pass).newlyConfirmedText
        }
        // Four enders: cut at the third-from-last, keeping the last two sentences as hypothesis.
        #expect(confirmed == "one two three. four five six.")
    }
}
