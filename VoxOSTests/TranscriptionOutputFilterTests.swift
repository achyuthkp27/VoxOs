import Testing

@testable import VoxOS

/// Only known non-speech markers are stripped; dictated parentheticals survive.
struct TranscriptionOutputFilterTests {
    @Test func stripsKnownNonSpeechMarkers() {
        #expect(TranscriptionOutputFilter.filter("[Music] hello [BLANK_AUDIO] there (laughs)") == "hello there")
        #expect(TranscriptionOutputFilter.filter("[ Silence ] okay [upbeat music playing]") == "okay")
        #expect(TranscriptionOutputFilter.filter("so (inaudible 00:12) yes") == "so yes")
        #expect(TranscriptionOutputFilter.filter("{applause} done [Speaking in foreign language]") == "done")
    }

    @Test func keepsRealParentheticals() {
        #expect(TranscriptionOutputFilter.filter("call me at (555) 123-4567") == "call me at (555) 123-4567")
        let aside = "the budget (see appendix) is final"
        #expect(TranscriptionOutputFilter.filter(aside) == aside)
        #expect(TranscriptionOutputFilter.filter("use items[0] and config{a}") == "use items[0] and config{a}")
    }

    @Test func markerKeywordMustBeAWholeWord() {
        #expect(TranscriptionOutputFilter.filter("(musical) chairs") == "(musical) chairs")
        #expect(TranscriptionOutputFilter.filter("that (sounds good)") == "that (sounds good)")
    }

    @Test func stillRemovesTagBlocks() {
        #expect(TranscriptionOutputFilter.filter("<think>plan</think> answer") == "answer")
    }
}
