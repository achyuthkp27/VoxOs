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

    // MARK: - The app's language

    private let german: (String) -> String = { ["Pasting": "Einfügen", "Paste Method": "Einfügemethode"][$0] ?? $0 }

    @Test func aSectionIsFoundByItsLabelsInTheAppsLanguage() {
        #expect(SettingsSearchMatcher(query: "einfügemeth", localize: german).matches(.pasting))
    }

    @Test func aSectionIsStillFoundByItsEnglishLabels() {
        #expect(SettingsSearchMatcher(query: "paste method", localize: german).matches(.pasting))
    }

    @Test func aTranslationOnlyFindsItsOwnSection() {
        #expect(!SettingsSearchMatcher(query: "einfügen", localize: german).matches(.recorder))
    }

    @Test func chineseMatchesInsideATermWithoutSpaces() {
        let chinese: (String) -> String = { $0 == "Paste Method" ? "粘贴方式" : $0 }
        #expect(SettingsSearchMatcher(query: "方式", localize: chinese).matches(.pasting))
    }
}

/// Sections shown only while a switch elsewhere on the page is on.
@Suite
struct SettingsPageLayoutTests {

    private func layout(homeOn: Bool) -> SettingsPageLayout {
        SettingsPageLayout(
            sections: [.notchLook, .notchHome, .notchMusic], dependents: [.notchMusic], on: .notchHome,
            isOn: homeOn)
    }

    @Test func withTheSwitchOnASectionShowsWhenItMatches() {
        let search = SettingsSearchMatcher(query: "lyrics")
        #expect(layout(homeOn: true).shows(.notchMusic, for: search))
        #expect(!layout(homeOn: true).shows(.notchHome, for: search))
    }

    @Test func withTheSwitchOffTheSectionHoldingItShowsInstead() {
        let search = SettingsSearchMatcher(query: "lyrics")
        #expect(!layout(homeOn: false).shows(.notchMusic, for: search))
        #expect(layout(homeOn: false).shows(.notchHome, for: search))
        #expect(layout(homeOn: false).hasMatches(for: search))
    }

    @Test func aHiddenSectionNeverShowsEvenWithoutAQuery() {
        let search = SettingsSearchMatcher(query: "")
        #expect(!layout(homeOn: false).shows(.notchMusic, for: search))
        #expect(layout(homeOn: false).shows(.notchLook, for: search))
    }

    @Test func aQueryNothingMatchesHasNoMatches() {
        #expect(!layout(homeOn: false).hasMatches(for: SettingsSearchMatcher(query: "zzzz")))
        #expect(!layout(homeOn: true).hasMatches(for: SettingsSearchMatcher(query: "zzzz")))
    }
}
