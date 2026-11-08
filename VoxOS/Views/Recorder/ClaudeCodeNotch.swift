import AppKit
import Combine
import SwiftUI
import os

/// Claude Code in the notch: a slim band beside the notch while a session works, and a card
/// that hangs from it when a session asks for permission.
///
/// Like the idle tab, this is its own persistent panel rather than a state of the recorder: the
/// recorder is built per dictation, and a permission request can arrive at any time. It steps
/// aside while the recorder is up and comes back when the dictation ends.
enum ClaudeCodeNotch {
    /// The spark, the check, or a count.
    static let glyphSize: CGFloat = 14
    /// How far the status band reaches past each side of the notch: the shoulder and the content
    /// inset (measured from the drawn body, which the scooped shoulder pulls in from the frame),
    /// the glyph, and the same inset again before the notch.
    static var wing: CGFloat {
        NotchDesign.listening.shoulder + NotchDesign.contentInset + glyphSize + NotchDesign.contentInset
    }
    /// From the frame's edge to the glyph: past the shoulder, then the usual content inset. On the
    /// approval card this lines the glyph up with the card's text.
    static func glyphInset(for content: Content) -> CGFloat {
        radii(for: content).shoulder + NotchDesign.contentInset
    }
    /// The card's measurements. Its height is worked out from these, not measured after layout,
    /// so the window can be exactly the shape before the shape is drawn.
    enum Card {
        static var top: CGFloat { AgentComposer.panelTopInset }
        static var bottom: CGFloat { AgentComposer.panelBottomInset }
        static let spacing: CGFloat = 8
        static let eyebrowHeight: CGFloat = 14
        static let titleLineHeight: CGFloat = 19
        static let titleCharactersPerLine = 48
        static let detailLineHeight: CGFloat = 15
        static let detailCharactersPerLine = 54
        static let detailMaxLines = 3
        static let detailPadding: CGFloat = 8
        static let buttonHeight: CGFloat = 30
        static let buttonGap: CGFloat = 12
        static let optionHeight: CGFloat = 38
        static let optionSpacing: CGFloat = 6
        /// A plan scrolls inside a box this many lines tall.
        static let planLines = 8
        static let planLineHeight: CGFloat = 16
        /// A change scrolls inside a box at most this many lines tall.
        static let diffLines = 7
        static let diffLineHeight: CGFloat = 15
        static let diffPadding: CGFloat = 6
    }

    /// Lines a text needs at a rough characters-per-line, capped; a newline always starts one.
    static func lines(of text: String, perLine: Int, max cap: Int) -> Int {
        let needed = text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) {
            $0 + Swift.max(1, Int((Double($1.count) / Double(perLine)).rounded(.up)))
        }
        return Swift.min(Swift.max(needed, 1), cap)
    }

    /// Height of the card below the notch row: a permission request, or the tallest of a set of
    /// questions so the card does not jump between them.
    static func cardContentHeight(for prompt: ClaudeCodeActivity.PermissionPrompt) -> CGFloat {
        let head = Card.top + Card.eyebrowHeight + Card.spacing
        if let questions = prompt.questions {
            let tallest =
                questions.map { question -> CGFloat in
                    let title = CGFloat(lines(of: question.question, perLine: Card.titleCharactersPerLine, max: 2))
                    // The options, then "Other…", which turns into a text field in place.
                    let rows = CGFloat(question.options.count + 1)
                    return title * Card.titleLineHeight + Card.spacing + rows * Card.optionHeight
                        + Swift.max(0, rows - 1) * Card.optionSpacing
                }.max() ?? 0
            let needsButton = questions.contains(where: \.multiSelect)
            return head + tallest + (needsButton ? Card.buttonGap + Card.buttonHeight : 0) + Card.bottom
        }
        if prompt.plan != nil {
            return head + Card.titleLineHeight + Card.spacing + planBoxHeight + Card.buttonGap + Card.buttonHeight
                + Card.bottom
        }
        var height = head + Card.titleLineHeight
        if !prompt.summary.detail.isEmpty {
            let detailLines = lines(
                of: prompt.summary.detail, perLine: Card.detailCharactersPerLine, max: Card.detailMaxLines)
            height += Card.spacing + CGFloat(detailLines) * Card.detailLineHeight + Card.detailPadding * 2
        }
        if let diff = prompt.diff, !diff.isEmpty {
            height += Card.spacing + diffBoxHeight(lines: diff.count)
        }
        return height + Card.buttonGap + Card.buttonHeight + Card.bottom
    }
    /// Whose request it is: the folder, the branch when there is one, and the session's title,
    /// which tells two sessions in one folder apart. The spark beside the notch says Claude Code.
    static func eyebrowParts(for prompt: ClaudeCodeActivity.PermissionPrompt) -> [String] {
        var parts = [prompt.project]
        if let branch = prompt.branch, !branch.isEmpty { parts.append(branch) }
        if let title = prompt.sessionTitle, !title.isEmpty { parts.append(title) }
        return parts
    }

    static func diffBoxHeight(lines count: Int) -> CGFloat {
        CGFloat(Swift.min(count, Card.diffLines)) * Card.diffLineHeight + Card.diffPadding * 2
    }

    static var planBoxHeight: CGFloat { CGFloat(Card.planLines) * Card.planLineHeight + Card.detailPadding * 2 }

    /// A plan's markdown, drawn plainly: headings in bold without their #, list markers as
    /// bullets, inline styles as markdown gives them, fenced code in mono without its fences.
    static func planText(_ markdown: String) -> AttributedString {
        var pieces: [AttributedString] = []
        var inFence = false
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(
            separator: "\n", omittingEmptySubsequences: false)
        {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                continue
            }
            var piece: AttributedString
            if inFence {
                piece = AttributedString(line)
                piece.swiftUI.font = .appMono(size: 11, weight: .regular)
            } else if trimmed.hasPrefix("#") {
                piece = inlineMarkdown(trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))
                piece.swiftUI.font = .app(size: 12, weight: .semibold)
            } else if let marker = ["- ", "* ", "+ "].first(where: { trimmed.hasPrefix($0) }) {
                let indent = String(line.prefix(while: { $0 == " " }))
                piece = inlineMarkdown(indent + "• " + trimmed.dropFirst(marker.count))
            } else {
                piece = inlineMarkdown(line)
            }
            pieces.append(piece)
        }
        var result = AttributedString()
        for (index, piece) in pieces.enumerated() {
            if index > 0 { result += AttributedString("\n") }
            result += piece
        }
        return result
    }

    private static func inlineMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    /// Claude's own coral, for the glyph only.
    static let claudeColor = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
    static let doneColor = Color(red: 0.42, green: 0.86, blue: 0.56)
    static let failedColor = Color(red: 1, green: 0.45, blue: 0.4)

    enum Content: Equatable {
        case hidden
        case status(ClaudeCodeActivity.Status)
        /// The first waiting request, and how many are waiting in all.
        case approval(ClaudeCodeActivity.PermissionPrompt, waiting: Int)

        /// The one-time "Show Claude Code in the notch?" card.
        case offer

        /// Requests whose session's terminal is in front: the terminal is asking already, so the
        /// notch only says how many wait, as a band, until it is clicked.
        case waiting(Int)

        /// Claude's last message when a turn ended (only when switched on).
        case reply(ClaudeCodeActivity.Reply)

        var isCard: Bool {
            switch self {
            case .approval, .offer, .reply: return true
            case .hidden, .status, .waiting: return false
            }
        }

        /// Notch Home steps aside: for a card, and for a request waiting as a band.
        var hidesHome: Bool {
            switch self {
            case .approval, .offer, .waiting, .reply: return true
            case .hidden, .status: return false
            }
        }
    }

    /// A request outranks status; the recorder outranks both, since the user is talking to it.
    /// `quiet`: the first request's terminal is in front and the user has not clicked for it.
    static func content(
        prompts: [ClaudeCodeActivity.PermissionPrompt], status: ClaudeCodeActivity.Status, enabled: Bool,
        approvalsEnabled: Bool, statusEnabled: Bool, recorderVisible: Bool, offering: Bool = false,
        homeVisible: Bool = false, quiet: Bool = false, reply: ClaudeCodeActivity.Reply? = nil
    ) -> Content {
        guard !recorderVisible else { return .hidden }
        if offering, !enabled { return .offer }
        guard enabled else { return .hidden }
        if approvalsEnabled, let first = prompts.first {
            return quiet ? .waiting(prompts.count) : .approval(first, waiting: prompts.count)
        }
        if let reply { return .reply(reply) }
        // The music band says more than "working" does, so it keeps the notch.
        if statusEnabled, !status.isEmpty, !homeVisible { return .status(status) }
        return .hidden
    }

    /// Size of the drawn shape, notch row included.
    static func size(for content: Content, notchWidth: CGFloat, notchHeight: CGFloat) -> CGSize {
        switch content {
        case .hidden:
            return CGSize(width: notchWidth, height: notchHeight)
        case .status, .waiting:
            return CGSize(width: notchWidth + wing * 2, height: notchHeight)
        case .approval(let prompt, _):
            return CGSize(
                width: max(NotchDesign.expandedWidth, notchWidth + wing * 2),
                height: notchHeight + cardContentHeight(for: prompt))
        case .offer:
            return CGSize(
                width: max(NotchDesign.expandedWidth, notchWidth + wing * 2), height: notchHeight + offerContentHeight)
        case .reply:
            return CGSize(
                width: max(NotchDesign.expandedWidth, notchWidth + wing * 2), height: notchHeight + replyContentHeight)
        }
    }

    /// The window is exactly the shape, hung from the top centre of the screen, so it never
    /// covers more of the menu bar than the band itself.
    static func frame(for size: CGSize, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height, width: size.width,
            height: size.height)
    }

    static func radii(for content: Content) -> NotchDesign.Radii {
        switch content {
        case .hidden: return NotchDesign.resting
        case .status, .waiting: return NotchDesign.listening
        case .approval, .offer, .reply: return NotchDesign.expanded
        }
    }

    static let offerMessage = String(
        localized:
            "See when a session is working, and allow or answer its requests here. This adds hooks to ~/.claude/settings.json."
    )
    static let offerMessageLineHeight: CGFloat = 16

    /// A reply shows this many lines, scrolling past them.
    static let replyLines = 4

    /// Eyebrow, the reply's box, and the buttons.
    static var replyContentHeight: CGFloat {
        Card.top + Card.eyebrowHeight + Card.spacing + CGFloat(replyLines) * Card.planLineHeight + Card.detailPadding
            * 2
            + Card.buttonGap + Card.buttonHeight + Card.bottom
    }

    /// Eyebrow, title, a two-line message, and the buttons.
    static var offerContentHeight: CGFloat {
        Card.top + Card.eyebrowHeight + Card.spacing + Card.titleLineHeight + Card.spacing + 2 * offerMessageLineHeight
            + Card.buttonGap + Card.buttonHeight + Card.bottom
    }
}

// MARK: - View

@MainActor
final class ClaudeCodeNotchModel: ObservableObject {
    @Published var content: ClaudeCodeNotch.Content = .hidden
    /// The app the first request's session runs in, for a button that brings it to the front.
    @Published var terminal: pid_t?
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    init(notchWidth: CGFloat, notchHeight: CGFloat) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
    }
}
