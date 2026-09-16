import Foundation
import Testing

@testable import VoxOS

@Suite
struct SettingsSearchMatcherTests {

    private let pasting = ["Pasting", "clipboard restore delay", "paste method", "trailing space"]

    @Test func anEmptyQueryShowsEverything() {
        let matcher = SettingsSearchMatcher(query: "")
        #expect(!matcher.isFiltering)
        #expect(matcher.matches(pasting))
        #expect(matcher.matches(["anything at all"]))
    }

    @Test func whitespaceOnlyIsNotAQuery() {
        let matcher = SettingsSearchMatcher(query: "   ")
        #expect(!matcher.isFiltering)
        #expect(matcher.matches(["unrelated"]))
    }

    @Test func aPrefixMatchesSoResultsNarrowWhileTyping() {
        // Each of these is a keystroke on the way to "clipboard".
        for typed in ["c", "cl", "clip", "clipboard"] {
            #expect(SettingsSearchMatcher(query: typed).matches(pasting), "failed at \(typed)")
        }
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(SettingsSearchMatcher(query: "CLIPBOARD").matches(pasting))
        #expect(SettingsSearchMatcher(query: "Paste").matches(pasting))
    }

    @Test func everyWordMustMatchSomewhere() {
        // Both words appear, in different keywords — extra words should narrow, not widen.
        #expect(SettingsSearchMatcher(query: "paste delay").matches(pasting))
        // "bluetooth" appears nowhere, so the section is out even though "paste" matched.
        #expect(!SettingsSearchMatcher(query: "paste bluetooth").matches(pasting))
    }

    @Test func wordsMayMatchInsideAMultiWordKeyword() {
        #expect(SettingsSearchMatcher(query: "restore").matches(pasting))
        #expect(SettingsSearchMatcher(query: "trailing").matches(pasting))
    }

    @Test func anUnrelatedQueryHidesTheSection() {
        #expect(!SettingsSearchMatcher(query: "microphone").matches(pasting))
    }

    @Test func punctuationInTheQueryIsIgnored() {
        #expect(SettingsSearchMatcher(query: "paste, delay!").matches(pasting))
    }

    @Test func aWordOnlyMatchesAtAWordBoundary() {
        // "board" is inside "clipboard" but is not how anyone searches for it; matching mid-word
        // would make almost everything match almost everything.
        #expect(!SettingsSearchMatcher(query: "board").matches(pasting))
    }
}
