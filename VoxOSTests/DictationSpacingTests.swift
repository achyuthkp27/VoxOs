import Foundation
import Testing

@testable import VoxOS

/// Spacing is applied to every dictation, so a wrong rule here is wrong thousands of times.
@Suite
struct DictationSpacingTests {

    private func decide(
        _ text: String, before: Character? = nil, after: Character? = nil, append: Bool = true
    ) -> DictationSpacing.Decision {
        DictationSpacing.decide(text: text, before: before, after: after, appendTrailingSpace: append)
    }

    @Test func dictatingStraightAfterAWordGetsALeadingSpace() {
        // The old behaviour produced "Helloworld " here.
        let decision = decide("world", before: "o")
        #expect(decision.leadingSpace)
        #expect(decision.applied(to: "world") == " world ")
    }

    @Test func anExistingSpaceIsNotDoubled() {
        #expect(!decide("world", before: " ").leadingSpace)
    }

    @Test func aNewLineCountsAsAlreadySeparated() {
        #expect(!decide("world", before: "\n").leadingSpace)
    }

    @Test func theStartOfAFieldNeedsNoLeadingSpace() {
        #expect(!decide("hello", before: nil).leadingSpace)
    }

    @Test func punctuationIsNotPushedAwayFromTheWordItBelongsTo() {
        // "Hello ," is wrong; "Hello," is what was meant.
        for piece in [".", ",", "!", "?", ";", ":", "’s"] {
            #expect(!decide(piece, before: "o").leadingSpace, "failed for \(piece)")
        }
    }

    @Test func anOpenBracketKeepsWhatFollowsTightToIt() {
        #expect(!decide("note", before: "(").leadingSpace)
    }

    @Test func aTrailingSpaceIsNotAddedWhenOneFollows() {
        #expect(!decide("hello", after: " ").trailingSpace)
    }

    @Test func aTrailingSpaceIsNotAddedBeforePunctuation() {
        // Dictating into "Hello| world." should not give "Hello there ." when the cursor sits
        // right before a full stop.
        #expect(!decide("there", after: ".").trailingSpace)
    }

    @Test func thePreferenceCanOnlyBeHonouredNeverOverridden() {
        // Context withdraws a trailing space; it must never add one the user switched off.
        #expect(!decide("hello", append: false).trailingSpace)
        #expect(!decide("hello", before: "o", after: "x", append: false).trailingSpace)
        // ...and leading spacing is independent of the preference, since it is about
        // separation rather than the user's trailing-space choice.
        #expect(decide("hello", before: "o", append: false).leadingSpace)
    }

    @Test func textThatAlreadyCarriesItsOwnSpacingIsLeftAlone() {
        #expect(!decide(" hello", before: "o").leadingSpace)
        #expect(!decide("hello ", after: nil).trailingSpace)
    }

    @Test func emptyTextGetsNoSpacesAtAll() {
        let decision = decide("")
        #expect(!decision.leadingSpace)
        #expect(!decision.trailingSpace)
        #expect(decision.applied(to: "") == "")
    }

    @Test func theCommonCaseStillBehavesAsBefore() {
        // Dictating into an empty field with the preference on: one trailing space, no leading.
        let decision = decide("hello there")
        #expect(!decision.leadingSpace)
        #expect(decision.trailingSpace)
        #expect(decision.applied(to: "hello there") == "hello there ")
    }

    @Test func unknownContextFallsBackToTheOldBehaviour() {
        // An app that will not report its insertion point must not get spacing invented for it.
        let decision = decide("hello", before: nil, after: nil)
        #expect(!decision.leadingSpace)
        #expect(decision.trailingSpace)
    }
}
