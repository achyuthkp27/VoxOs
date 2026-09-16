import Foundation
import Testing

@testable import VoxOS

/// Pure-logic checks for the raw-vs-enhanced history diff. No UI, no model context.
@Suite
struct TranscriptionTextDiffTests {

    @Test func identicalTextHasNoDiff() {
        #expect(TranscriptionTextDiff.compare(original: "hello there", enhanced: "hello there") == nil)
    }

    @Test func aSingleCorrectionLeavesTheRestAlone() throws {
        let diff = try #require(
            TranscriptionTextDiff.compare(
                original: "lets go to the stor",
                enhanced: "let's go to the store"))

        #expect(diff.hasChanges)
        // The words enhancement did not touch must not be marked, or the highlight is noise.
        let untouched = diff.enhanced.filter { !$0.changed }.map(\.text).joined()
        #expect(untouched.contains("go to the"))
    }

    @Test func adjacentRunsOfTheSameStateAreCoalesced() throws {
        let diff = try #require(
            TranscriptionTextDiff.compare(
                original: "one two three four five",
                enhanced: "one two three four FIVE"))

        // Runs exist so the view can style a phrase in one Text instead of one per word;
        // two neighbours sharing a state would mean that collapsing failed.
        for (a, b) in zip(diff.enhanced, diff.enhanced.dropFirst()) {
            #expect(a.changed != b.changed)
        }
    }

    @Test func runsReassembleIntoTheOriginalStrings() throws {
        let original = "the quick brown fox, jumped over  the lazy dog"
        let enhanced = "The quick brown fox jumped over the lazy dog."
        let diff = try #require(TranscriptionTextDiff.compare(original: original, enhanced: enhanced))

        // Whitespace is tokenised separately precisely so this holds. If it does not, the view
        // renders text that differs from what was actually transcribed.
        #expect(diff.original.map(\.text).joined() == original)
        #expect(diff.enhanced.map(\.text).joined() == enhanced)
    }

    @Test func punctuationOnlyEditsAreStillChanges() throws {
        let diff = try #require(TranscriptionTextDiff.compare(original: "yes", enhanced: "yes!"))
        #expect(diff.hasChanges)
    }

    @Test func changedWordCountIgnoresPunctuationAndSpacing() throws {
        let diff = try #require(
            TranscriptionTextDiff.compare(original: "i went home", enhanced: "I went home."))
        // "i" became "I" and a full stop was added; only the word counts toward the summary.
        #expect(diff.changedWordCount == 1)
        #expect(diff.summary == "1 word changed")
    }

    @Test func oversizedInputIsDeclinedRatherThanRunSlowly() {
        // difference(from:) is quadratic in the worst case and this runs while a row expands.
        let big = String(repeating: "word ", count: 3000)
        #expect(TranscriptionTextDiff.compare(original: big, enhanced: big + "tail") == nil)
    }

    @Test func everythingIsNewWhenThereWasNoOriginal() throws {
        let diff = try #require(TranscriptionTextDiff.compare(original: "", enhanced: "added text"))
        #expect(diff.hasChanges)
        // Computed outside #expect: allSatisfy is rethrows, which the macro treats as throwing.
        let everyRunIsNew = diff.enhanced.allSatisfy(\.changed)
        #expect(everyRunIsNew)
    }
}
