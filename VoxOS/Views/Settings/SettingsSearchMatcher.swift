import Foundation

/// Decides which settings sections a search query keeps on screen.
///
/// Settings grew to ten sections across shortcuts, audio, the Agent, MCP, pasting, interface and
/// diagnostics, which is more than fits on a screen or in a reader's head. Filtering by keyword
/// beats scrolling and guessing which heading a toggle lives under.
///
/// Matching is per word so that "paste delay" finds the clipboard restore delay even though no
/// single keyword contains both words, and words match as prefixes so results narrow while
/// typing rather than appearing only on the last character.
struct SettingsSearchMatcher {
    let query: String
    /// Turns a label into the text the app shows for it in the user's language.
    private let localize: (String) -> String

    init(query: String, localize: @escaping (String) -> String = Self.appLocalization) {
        self.query = query
        self.localize = localize
    }

    /// The label as the running app shows it: its translation, or the label itself when it has none.
    static func appLocalization(_ label: String) -> String {
        Bundle.main.localizedString(forKey: label, value: label, table: nil)
    }

    private var words: [Substring] {
        query
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
    }

    /// With no query every section shows, so the unfiltered view is the normal one.
    var isFiltering: Bool { !words.isEmpty }

    /// True when every word in the query matches somewhere in `terms`.
    ///
    /// Requiring all of them means extra words narrow the results, which is what typing more is
    /// for; matching any word would widen them instead.
    func matches(_ terms: [String]) -> Bool {
        guard isFiltering else { return true }
        let haystack = terms.map { $0.lowercased() }
        return words.allSatisfy { word in
            // Chinese and Japanese put no spaces between words, so a word there can start
            // anywhere in a term rather than only after a space.
            let unspaced = word.unicodeScalars.contains { $0.properties.isIdeographic }
            return haystack.contains { term in
                unspaced
                    ? term.contains(word)
                    : term.split { !$0.isLetter && !$0.isNumber }.contains { $0.hasPrefix(word) }
            }
        }
    }

    func matches(_ terms: String...) -> Bool {
        matches(terms)
    }

    /// Matches a section's labels as written and as the app shows them in the user's language,
    /// so a search finds the words on screen whichever language that is.
    func matches(_ section: SettingsSection) -> Bool {
        guard isFiltering else { return true }
        let translated = section.labels.map(localize).filter { !section.labels.contains($0) }
        return matches(section.terms + translated)
    }

    /// True when there is no query, or when at least one of `sections` matches it.
    func matchesAny(_ sections: [SettingsSection]) -> Bool {
        !isFiltering || sections.contains { matches($0) }
    }
}

/// Which of a page's sections a search shows, when some are drawn only while a switch in another
/// section is on.
struct SettingsPageLayout {
    let sections: [SettingsSection]
    /// Sections not drawn right now, each with the section holding the switch that brings it back.
    let hidden: [SettingsSection: SettingsSection]

    init(sections: [SettingsSection], hidden: [SettingsSection: SettingsSection] = [:]) {
        self.sections = sections
        self.hidden = hidden
    }

    /// Hides `dependents` behind `parent`'s switch while `isOn` is false.
    init(sections: [SettingsSection], dependents: [SettingsSection], on parent: SettingsSection, isOn: Bool) {
        self.init(
            sections: sections, hidden: isOn ? [:] : Dictionary(uniqueKeysWithValues: dependents.map { ($0, parent) }))
    }

    /// A hidden section never shows. Its parent shows in its place when the hidden one matches,
    /// since turning that switch on is how to reach it.
    func shows(_ section: SettingsSection, for search: SettingsSearchMatcher) -> Bool {
        guard hidden[section] == nil else { return false }
        return search.matches(section) || hidden.contains { $0.value == section && search.matches($0.key) }
    }

    /// False only while searching and nothing on the page would show.
    func hasMatches(for search: SettingsSearchMatcher) -> Bool {
        !search.isFiltering || sections.contains { shows($0, for: search) }
    }
}
