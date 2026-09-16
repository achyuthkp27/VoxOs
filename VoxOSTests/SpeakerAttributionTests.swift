import Foundation
import Testing

@testable import VoxOS

/// Joining "who spoke when" to "what was said" is interval overlap; these pin down the cases
/// where a naive join would attribute words to the wrong person.
@Suite
struct SpeakerAttributionTests {

    private func token(_ text: String, _ start: Double, _ end: Double) -> SpeakerAttribution.TimedToken {
        .init(text: text, startTime: start, endTime: end)
    }

    private func speaker(_ id: String, _ start: Double, _ end: Double) -> SpeakerAttribution.SpeakerRange {
        .init(speakerId: id, startTime: start, endTime: end)
    }

    @Test func nothingInNothingOut() {
        #expect(SpeakerAttribution.turns(tokens: [], speakers: [speaker("a", 0, 5)]).isEmpty)
        #expect(SpeakerAttribution.turns(tokens: [token("hi", 0, 1)], speakers: []).isEmpty)
    }

    @Test func consecutiveTokensFromOneSpeakerBecomeOneTurn() {
        let turns = SpeakerAttribution.turns(
            tokens: [token("hello", 0, 0.5), token("there", 0.5, 1.0)],
            speakers: [speaker("a", 0, 2)])

        #expect(turns.count == 1)
        #expect(turns.first?.text == "hello there")
        #expect(turns.first?.startTime == 0)
        #expect(turns.first?.endTime == 1.0)
    }

    @Test func aSpeakerChangeStartsANewTurn() {
        let turns = SpeakerAttribution.turns(
            tokens: [token("hello", 0, 1), token("hi", 2, 3)],
            speakers: [speaker("a", 0, 1.5), speaker("b", 1.5, 4)])

        #expect(turns.map(\.speakerId) == ["a", "b"])
        #expect(turns.map(\.text) == ["hello", "hi"])
    }

    @Test func aTokenStraddlingAHandoverGoesToWhoeverSpokeMostOfIt() {
        // 1.0–2.0 with the change at 1.8: 0.8s of A against 0.2s of B.
        let turns = SpeakerAttribution.turns(
            tokens: [token("borderline", 1.0, 2.0)],
            speakers: [speaker("a", 0, 1.8), speaker("b", 1.8, 5)])
        #expect(turns.first?.speakerId == "a")

        // Same token, change at 1.2: now B owns most of it.
        let other = SpeakerAttribution.turns(
            tokens: [token("borderline", 1.0, 2.0)],
            speakers: [speaker("a", 0, 1.2), speaker("b", 1.2, 5)])
        #expect(other.first?.speakerId == "b")
    }

    @Test func tokensInSilenceAreDroppedRatherThanGuessed() {
        // Diarization leaves gaps for non-speech; attributing there puts words in a mouth.
        let turns = SpeakerAttribution.turns(
            tokens: [token("hello", 0, 1), token("cough", 5, 6), token("bye", 10, 11)],
            speakers: [speaker("a", 0, 2), speaker("a", 9, 12)])

        #expect(turns.map(\.text) == ["hello", "bye"])
    }

    @Test func aSpeakerReturningStartsAFreshTurn() {
        let turns = SpeakerAttribution.turns(
            tokens: [token("one", 0, 1), token("two", 2, 3), token("three", 4, 5)],
            speakers: [speaker("a", 0, 1.5), speaker("b", 1.5, 3.5), speaker("a", 3.5, 6)])

        #expect(turns.map(\.speakerId) == ["a", "b", "a"])
        #expect(turns.count == 3)
    }

    @Test func punctuationAttachesToTheWordBeforeIt() {
        let turns = SpeakerAttribution.turns(
            tokens: [token("hello", 0, 1), token(",", 1, 1.1), token("world", 1.1, 2), token("!", 2, 2.1)],
            speakers: [speaker("a", 0, 3)])
        #expect(turns.first?.text == "hello, world!")
    }

    @Test func emptyAndWhitespaceTokensAreIgnored() {
        let turns = SpeakerAttribution.turns(
            tokens: [token("hi", 0, 1), token("   ", 1, 1.1), token("", 1.1, 1.2), token("there", 1.2, 2)],
            speakers: [speaker("a", 0, 3)])
        #expect(turns.first?.text == "hi there")
    }

    @Test func labelsAreNumberedByFirstAppearanceAndStayStable() {
        let turns = [
            SpeakerAttribution.Turn(speakerId: "xyz", text: "first", startTime: 0, endTime: 1),
            SpeakerAttribution.Turn(speakerId: "abc", text: "second", startTime: 1, endTime: 2),
            SpeakerAttribution.Turn(speakerId: "xyz", text: "third", startTime: 2, endTime: 3),
        ]
        // Numbering follows who spoke first, not the diarizer's internal ids, so it does not
        // reshuffle between runs.
        #expect(
            SpeakerAttribution.transcript(turns) == """
                Speaker 1: first
                Speaker 2: second
                Speaker 1: third
                """)
    }

    @Test func chosenNamesReplaceTheDefaultLabels() {
        let turns = [
            SpeakerAttribution.Turn(speakerId: "xyz", text: "hello", startTime: 0, endTime: 1),
            SpeakerAttribution.Turn(speakerId: "abc", text: "hi", startTime: 1, endTime: 2),
        ]
        let rendered = SpeakerAttribution.transcript(turns, names: ["xyz": "Achyuth"])
        #expect(rendered == "Achyuth: hello\nSpeaker 2: hi")
    }
}
