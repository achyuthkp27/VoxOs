import Foundation

/// Decides the spacing around dictated text at the point it is inserted.
///
/// The old behaviour was one unconditional trailing space, which is wrong in both directions.
/// Dictating straight after existing text produced "Helloworld " because nothing ever added a
/// leading space, and dictating where a space already sat produced two.
///
/// Everything here is decided from the characters either side of the insertion point, so it is a
/// plain value type with tests rather than logic living in the paste path.
enum DictationSpacing {

    struct Decision: Equatable {
        var leadingSpace: Bool
        var trailingSpace: Bool

        func applied(to text: String) -> String {
            (leadingSpace ? " " : "") + text + (trailingSpace ? " " : "")
        }
    }

    /// Punctuation that belongs tight against the word before it, so a leading space would
    /// strand it: "Hello ," rather than "Hello,".
    private static let attachesLeft: Set<Character> = [
        ".", ",", "!", "?", ";", ":", ")", "]", "}", "'", "’", "”", "%", "…",
    ]

    /// Openers that belong tight against what follows, so a trailing space would strand them.
    private static let attachesRight: Set<Character> = ["(", "[", "{", "“", "#", "@", "$"]

    /// - Parameters:
    ///   - text: what is about to be inserted.
    ///   - before: the character immediately before the insertion point, or nil at the start of
    ///     the field or when the app will not tell us.
    ///   - after: the character immediately after it, same caveat.
    ///   - appendTrailingSpace: the user's preference. A trailing space is never added when it is
    ///     off; the rest of the rules only ever take one away.
    static func decide(
        text: String,
        before: Character?,
        after: Character?,
        appendTrailingSpace: Bool
    ) -> Decision {
        guard let first = text.first, let last = text.last else {
            return Decision(leadingSpace: false, trailingSpace: false)
        }

        // Nothing to separate from: start of field, start of line, or a space already there.
        // A nil `before` means the app did not say, and inventing a space that shifts the user's
        // text is worse than leaving the old behaviour in place.
        let needsLeading: Bool
        if let before {
            needsLeading =
                !before.isWhitespace
                && !attachesLeft.contains(first)
                && !attachesRight.contains(before)
                && !first.isWhitespace
        } else {
            needsLeading = false
        }

        // The preference decides whether there is a trailing space at all; context can only
        // withdraw it, never add one the user switched off.
        var needsTrailing = appendTrailingSpace && !last.isWhitespace && !attachesRight.contains(last)
        if let after, after.isWhitespace || attachesLeft.contains(after) {
            // A space already follows, or the next character is punctuation that would be
            // stranded by one.
            needsTrailing = false
        }

        return Decision(leadingSpace: needsLeading, trailingSpace: needsTrailing)
    }
}
