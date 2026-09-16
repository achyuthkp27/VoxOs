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

    init(query: String) {
        self.query = query
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
            haystack.contains { term in
                term.split { !$0.isLetter && !$0.isNumber }.contains { $0.hasPrefix(word) }
            }
        }
    }

    func matches(_ terms: String...) -> Bool {
        matches(terms)
    }
}
