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
        var height = head + Card.titleLineHeight
        if !prompt.summary.detail.isEmpty {
            let detailLines = lines(
                of: prompt.summary.detail, perLine: Card.detailCharactersPerLine, max: Card.detailMaxLines)
            height += Card.spacing + CGFloat(detailLines) * Card.detailLineHeight + Card.detailPadding * 2
        }
        return height + Card.buttonGap + Card.buttonHeight + Card.bottom
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

        var isCard: Bool {
            switch self {
            case .approval, .offer: return true
            case .hidden, .status: return false
            }
        }
    }

    /// A request outranks status; the recorder outranks both, since the user is talking to it.
    static func content(
        prompts: [ClaudeCodeActivity.PermissionPrompt], status: ClaudeCodeActivity.Status, enabled: Bool,
        approvalsEnabled: Bool, statusEnabled: Bool, recorderVisible: Bool, offering: Bool = false,
        homeVisible: Bool = false
    ) -> Content {
        guard !recorderVisible else { return .hidden }
        if offering, !enabled { return .offer }
        guard enabled else { return .hidden }
        if approvalsEnabled, let first = prompts.first { return .approval(first, waiting: prompts.count) }
        // The music band says more than "working" does, so it keeps the notch.
        if statusEnabled, !status.isEmpty, !homeVisible { return .status(status) }
        return .hidden
    }

    /// Size of the drawn shape, notch row included.
    static func size(for content: Content, notchWidth: CGFloat, notchHeight: CGFloat) -> CGSize {
        switch content {
        case .hidden:
            return CGSize(width: notchWidth, height: notchHeight)
        case .status:
            return CGSize(width: notchWidth + wing * 2, height: notchHeight)
        case .approval(let prompt, _):
            return CGSize(
                width: max(NotchDesign.expandedWidth, notchWidth + wing * 2),
                height: notchHeight + cardContentHeight(for: prompt))
        case .offer:
            return CGSize(
                width: max(NotchDesign.expandedWidth, notchWidth + wing * 2), height: notchHeight + offerContentHeight)
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
        case .status: return NotchDesign.listening
        case .approval, .offer: return NotchDesign.expanded
        }
    }

    static let offerMessage = String(
        localized:
            "See when a session is working, and allow or answer its requests here. This adds hooks to ~/.claude/settings.json."
    )
    static let offerMessageLineHeight: CGFloat = 16

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
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    init(notchWidth: CGFloat, notchHeight: CGFloat) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
    }
}

struct ClaudeCodeNotchView: View {
    @ObservedObject var model: ClaudeCodeNotchModel
    let onDecision: (UUID, ClaudeCodeActivity.Decision) -> Void
    let onOffer: (Bool) -> Void
    let onKeyboard: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var content: ClaudeCodeNotch.Content { model.content }
    private var size: CGSize {
        ClaudeCodeNotch.size(for: content, notchWidth: model.notchWidth, notchHeight: model.notchHeight)
    }
    private var shape: NotchShape { NotchShape(ClaudeCodeNotch.radii(for: content)) }

    var body: some View {
        VStack(spacing: 0) {
            notchRow
            if case .approval(let prompt, _) = content {
                Group {
                    if let questions = prompt.questions {
                        ClaudeCodeQuestionCard(
                            prompt: prompt, questions: questions, onDecision: onDecision, onKeyboard: onKeyboard)
                    } else {
                        ClaudeCodeApprovalCard(prompt: prompt, onDecision: onDecision)
                    }
                }
                // A new request starts fresh: no answers or selection carried over from the last.
                .id(prompt.id)
                .frame(height: ClaudeCodeNotch.cardContentHeight(for: prompt), alignment: .top)
                .transition(.opacity)
            }
            if content == .offer {
                ClaudeCodeOfferCard(onAnswer: onOffer)
                    .frame(height: ClaudeCodeNotch.offerContentHeight, alignment: .top)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(background)
        .contentShape(shape)
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : animation, value: content)
    }

    private var animation: Animation {
        content == .hidden ? NotchDesign.closeAnimation : NotchDesign.openAnimation
    }

    // MARK: Notch row

    private var notchRow: some View {
        HStack(spacing: 0) {
            leftWing.frame(width: ClaudeCodeNotch.glyphSize, height: ClaudeCodeNotch.glyphSize)
            Spacer(minLength: 0)
            rightWing.fixedSize().frame(minWidth: ClaudeCodeNotch.glyphSize, alignment: .trailing)
        }
        .padding(.horizontal, ClaudeCodeNotch.glyphInset(for: content))
        .frame(width: size.width, height: model.notchHeight)
        .opacity(content == .hidden ? 0 : 1)
    }

    @ViewBuilder
    private var leftWing: some View {
        switch content {
        case .status(let status) where status.working == 0 && status.finished == .done:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(ClaudeCodeNotch.doneColor)
                .accessibilityLabel(Text("Claude Code finished"))
        case .status(let status) where status.working == 0 && status.finished == .failed:
            Image(systemName: "exclamationmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(ClaudeCodeNotch.failedColor)
                .accessibilityLabel(Text("Claude Code stopped with an error"))
        case .status:
            ClaudeCodeSpark(spinning: !reduceMotion)
                .accessibilityLabel(Text("Claude Code is working"))
        case .offer:
            ClaudeCodeSpark(spinning: false)
                .accessibilityLabel(Text("Claude Code"))
        case .approval(let prompt, _):
            ClaudeCodeSpark(spinning: false)
                .accessibilityLabel(
                    Text(prompt.questions == nil ? "Claude Code is asking for permission" : "Claude Code is asking you")
                )
        case .hidden:
            Color.clear
        }
    }

    @ViewBuilder
    private var rightWing: some View {
        switch content {
        case .status(let status) where status.working > 1:
            Text(verbatim: "\(status.working)")
                .font(.appMono(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .accessibilityLabel(Text("\(status.working) sessions working"))
        case .approval(_, let waiting) where waiting > 1:
            Text(verbatim: "+\(waiting - 1)")
                .font(.appMono(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.75))
                .accessibilityLabel(Text("\(waiting - 1) more waiting"))
        default:
            Color.clear
        }
    }

    // MARK: Material

    /// One black surface, as the music card: glass under a black notch row read as a dark strip
    /// across the top.
    private var background: some View {
        shape.fill(NotchDesign.solid).overlay(rim)
    }

    private var rim: some View {
        shape.stroke(NotchDesign.rim, lineWidth: NotchDesign.rimWidth)
            .mask(LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35)))
            .opacity(content == .hidden ? 0 : 1)
    }
}

/// Claude Code's spark, turning slowly while a session works.
private struct ClaudeCodeSpark: View {
    let spinning: Bool
    @State private var angle: Double = 0

    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ClaudeCodeNotch.claudeColor)
            .rotationEffect(.degrees(angle))
            .onAppear {
                guard spinning else { return }
                withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) { angle = 360 }
            }
    }
}

/// Asked once: turn the integration on from the notch itself.
private struct ClaudeCodeOfferCard: View {
    typealias Card = ClaudeCodeNotch.Card
    let onAnswer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Card.spacing) {
            ClaudeCodeEyebrow(text: "VoxOS · Claude Code")

            Text("Show Claude Code in the notch?")
                .font(.app(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(height: Card.titleLineHeight)

            Text(verbatim: ClaudeCodeNotch.offerMessage)
                .font(.app(size: 12))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 2 * ClaudeCodeNotch.offerMessageLineHeight, alignment: .topLeading)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ClaudeCodeNotchButton(title: String(localized: "Not now"), prominent: false) { onAnswer(false) }
                ClaudeCodeNotchButton(title: String(localized: "Turn on"), prominent: true) { onAnswer(true) }
            }
            .padding(.top, Card.buttonGap - Card.spacing)
        }
        .padding(.top, Card.top)
        .padding(.horizontal, AgentComposer.panelInset)
        .padding(.bottom, Card.bottom)
    }
}

/// The eyebrow above every card: whose request it is.
private struct ClaudeCodeEyebrow: View {
    let text: String

    var body: some View {
        Text(verbatim: text.uppercased())
            .font(.appMono(size: 11, weight: .medium))
            .tracking(0.6)
            .foregroundStyle(.white.opacity(0.55))
            .lineLimit(1)
            .frame(height: ClaudeCodeNotch.Card.eyebrowHeight)
    }
}

/// A permission request: what the tool wants to do, and the terminal dialog's answers. The two
/// extra ones show only when the CLI offers them, as quiet text beside the two that matter.
private struct ClaudeCodeApprovalCard: View {
    typealias Card = ClaudeCodeNotch.Card
    let prompt: ClaudeCodeActivity.PermissionPrompt
    let onDecision: (UUID, ClaudeCodeActivity.Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Card.spacing) {
            ClaudeCodeEyebrow(text: "Claude Code · \(prompt.project)")

            Text(prompt.summary.title)
                .font(.app(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(height: Card.titleLineHeight)

            if !prompt.summary.detail.isEmpty {
                let lines = ClaudeCodeNotch.lines(
                    of: prompt.summary.detail, perLine: Card.detailCharactersPerLine, max: Card.detailMaxLines)
                Text(verbatim: prompt.summary.detail)
                    .font(.appMono(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(lines)
                    .multilineTextAlignment(.leading)
                    // Exactly the height cardContentHeight counted, so the buttons stay on the body.
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: CGFloat(lines) * Card.detailLineHeight, alignment: .topLeading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, Card.detailPadding)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.07)))
                    .help(prompt.summary.detail)
            }

            HStack(spacing: 4) {
                if let alwaysAllow = prompt.alwaysAllow {
                    ClaudeCodeQuietButton(title: String(localized: "Always allow"), help: alwaysAllow) {
                        onDecision(prompt.id, .allowAlways)
                    }
                }
                if prompt.canSwitchToAutoMode {
                    ClaudeCodeQuietButton(
                        title: String(localized: "Auto mode"),
                        help: String(localized: "Allow, and stop asking for the rest of this session")
                    ) {
                        onDecision(prompt.id, .allowInAutoMode)
                    }
                }
                Spacer(minLength: 8)
                ClaudeCodeNotchButton(title: String(localized: "Deny"), prominent: false) {
                    onDecision(prompt.id, .deny)
                }
                .padding(.trailing, 4)
                ClaudeCodeNotchButton(title: String(localized: "Allow"), prominent: true) {
                    onDecision(prompt.id, .allow)
                }
            }
            .padding(.top, Card.buttonGap - Card.spacing)
        }
        .padding(.top, Card.top)
        .padding(.horizontal, AgentComposer.panelInset)
        .padding(.bottom, Card.bottom)
    }
}

/// AskUserQuestion: one question at a time. A tap answers a single-choice question (and moves
/// to the next one); a multiple-choice question collects ticks and is sent with the button.
private struct ClaudeCodeQuestionCard: View {
    typealias Card = ClaudeCodeNotch.Card
    let prompt: ClaudeCodeActivity.PermissionPrompt
    let questions: [ClaudeCodeQuestion]
    let onDecision: (UUID, ClaudeCodeActivity.Decision) -> Void
    /// Asks the panel to take the keyboard (true) or give it back (false).
    let onKeyboard: (Bool) -> Void
    @State private var index = 0
    @State private var answers: [String: String] = [:]
    @State private var picked: Set<String> = []
    @State private var typing = false
    @State private var typed = ""
    @FocusState private var fieldFocused: Bool

    private var question: ClaudeCodeQuestion { questions[min(index, questions.count - 1)] }
    private var isLast: Bool { index >= questions.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: Card.spacing) {
            ClaudeCodeEyebrow(text: eyebrow)

            Text(question.question)
                .font(.app(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: Card.optionSpacing) {
                ForEach(question.options, id: \.label) { option in
                    ClaudeCodeOptionRow(
                        option: option, multiSelect: question.multiSelect, picked: picked.contains(option.label)
                    ) {
                        choose(option.label)
                    }
                }
                if typing {
                    otherField
                } else {
                    ClaudeCodeOptionRow(
                        option: .init(label: String(localized: "Other…"), description: ""), multiSelect: false,
                        picked: false
                    ) {
                        typing = true
                        onKeyboard(true)
                        fieldFocused = true
                    }
                }
            }

            if question.multiSelect {
                HStack {
                    Spacer(minLength: 0)
                    ClaudeCodeNotchButton(
                        title: isLast ? String(localized: "Send") : String(localized: "Next"), prominent: true
                    ) {
                        record(question.answer(choosing: picked))
                    }
                    .disabled(picked.isEmpty)
                    .opacity(picked.isEmpty ? 0.5 : 1)
                }
                .padding(.top, Card.buttonGap - Card.spacing)
            }
        }
        .padding(.top, Card.top)
        .padding(.horizontal, AgentComposer.panelInset)
        .padding(.bottom, Card.bottom)
    }

    /// "Other…" in place: the answer typed in the notch, as the terminal's Other would take it.
    private var otherField: some View {
        HStack(spacing: 8) {
            TextField(String(localized: "Your answer"), text: $typed)
                .textFieldStyle(.plain)
                .font(.app(size: 13))
                .foregroundStyle(.white)
                .focused($fieldFocused)
                .onSubmit(sendTyped)
                .onExitCommand(perform: stopTyping)
            ClaudeCodeNotchButton(title: String(localized: "Send"), prominent: true, action: sendTyped)
                .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: Card.optionHeight)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(
                AppTheme.Accent.primary.opacity(0.7), lineWidth: 1)
        )
        .onAppear { fieldFocused = true }
        // Answered in the terminal while typing here: the panel gives the keyboard back.
        .onDisappear { onKeyboard(false) }
    }

    private func sendTyped() {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Ticks already made on a multiple-choice question are kept, the typed answer last.
        let ticked = question.multiSelect ? question.answer(choosing: picked) : ""
        stopTyping()
        record(ticked.isEmpty ? text : ticked + ", " + text)
    }

    private func stopTyping() {
        typing = false
        typed = ""
        fieldFocused = false
        onKeyboard(false)
    }

    private var eyebrow: String {
        var parts = ["Claude Code", prompt.project]
        if !question.header.isEmpty { parts.append(question.header) }
        if questions.count > 1 { parts.append("\(index + 1)/\(questions.count)") }
        return parts.joined(separator: " · ")
    }

    private func choose(_ label: String) {
        guard question.multiSelect else { return record(label) }
        if picked.contains(label) { picked.remove(label) } else { picked.insert(label) }
    }

    private func record(_ answer: String) {
        answers[question.question] = answer
        picked = []
        if isLast {
            onDecision(prompt.id, .answer(answers))
        } else {
            index += 1
        }
    }
}

private struct ClaudeCodeOptionRow: View {
    typealias Card = ClaudeCodeNotch.Card
    let option: ClaudeCodeQuestion.Option
    let multiSelect: Bool
    let picked: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: option.label)
                        .font(.app(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if option.addsToLabel {
                        Text(verbatim: option.description)
                            .font(.app(size: 11))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if multiSelect {
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(picked ? AppTheme.Accent.primary : .white.opacity(0.35))
                }
            }
            .padding(.horizontal, 12)
            .frame(height: Card.optionHeight)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(option.description)
        .accessibilityLabel(Text(verbatim: option.label))
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    private var fill: Color {
        if picked { return AppTheme.Accent.primary.opacity(0.22) }
        return .white.opacity(hovered ? 0.11 : 0.06)
    }
}

/// A secondary choice: text only, so the two real buttons stay the obvious ones.
private struct ClaudeCodeQuietButton: View {
    let title: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.app(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(hovered ? 0.95 : 0.6))
                .padding(.horizontal, 6)
                .frame(height: ClaudeCodeNotch.Card.buttonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text(help))
    }
}

private struct ClaudeCodeNotchButton: View {
    let title: String
    let prominent: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.app(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 30)
                .background(Capsule().fill(fill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(Text(title))
    }

    private var fill: Color {
        if prominent { return AppTheme.Accent.primary.opacity(hovered ? 1 : 0.88) }
        return .white.opacity(hovered ? 0.16 : 0.10)
    }
}

// MARK: - Panel

final class ClaudeCodeNotchPanel: NSPanel {
    /// Only while an "Other…" answer is being typed: otherwise answering a request must not take
    /// focus from the app the user is typing into.
    var acceptsKeyboard = false
    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect, styleMask: [.nonactivatingPanel, .fullSizeContentView, .hudWindow],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        canHide = false
        // Above the idle tab, below the recorder.
        level = .statusBar + 2
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        styleMask.remove(.titled)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovable = false
    }
}

// MARK: - Manager

/// Owns the panel and decides what it shows.
@MainActor
final class ClaudeCodeNotchManager {
    private weak var uiManager: RecorderUIManager?
    private let activity: ClaudeCodeActivity
    private var panel: ClaudeCodeNotchPanel?
    private var model: ClaudeCodeNotchModel?
    private var screen: NSScreen?
    private var cancellables: Set<AnyCancellable> = []
    private var resizeTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "ClaudeCodeNotch")

    init(uiManager: RecorderUIManager, activity: ClaudeCodeActivity = .shared) {
        self.uiManager = uiManager
        self.activity = activity

        // @Published sends before the value is stored; hopping to the next run loop pass reads
        // the new value.
        activity.$prompts.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        activity.$sessions.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        ClaudeCodeIntegration.shared.$isOffering.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        uiManager.$isRecorderPanelVisible.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        uiManager.$isNotchHomeVisible.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        LifecycleObserver.shared.publisher(for: [.screenConfigurationChanged, .systemDidWake])
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.destroyPanel()
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    private func refresh() {
        guard let uiManager else { return }
        let now = Date()
        let content = ClaudeCodeNotch.content(
            prompts: activity.prompts, status: activity.status(now: now), enabled: ClaudeCodeIntegration.isEnabled,
            approvalsEnabled: ClaudeCodeIntegration.approvalsEnabled,
            statusEnabled: ClaudeCodeIntegration.statusEnabled,
            recorderVisible: uiManager.isRecorderPanelVisible, offering: ClaudeCodeIntegration.shared.isOffering,
            homeVisible: uiManager.isNotchHomeVisible)
        scheduleTick(after: now)
        apply(content)
        if uiManager.isClaudeCodeSurfaceVisible != (content != .hidden) {
            uiManager.isClaudeCodeSurfaceVisible = content != .hidden
        }
        if uiManager.isClaudeCodeCardVisible != content.isCard {
            uiManager.isClaudeCodeCardVisible = content.isCard
        }
    }

    /// "Done" fades by itself; nothing else happens then, so wake up for it.
    private func scheduleTick(after now: Date) {
        tickTask?.cancel()
        guard let next = activity.nextStatusChange(after: now) else { return }
        tickTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, next.timeIntervalSince(now) + 0.05)))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func apply(_ content: ClaudeCodeNotch.Content) {
        if content == .hidden {
            guard let panel, let model, model.content != .hidden else { return }
            resizeTask?.cancel()
            model.content = .hidden
            resizeTask = Task { @MainActor [weak panel] in
                try? await Task.sleep(for: .seconds(NotchDesign.closeDuration))
                guard !Task.isCancelled else { return }
                panel?.orderOut(nil)
            }
            return
        }

        // Every tool call refreshes; most of them change nothing on screen.
        if let panel, let model, panel.isVisible, model.content == content { return }
        if panel == nil { buildPanel() }
        guard let panel, let model, let screen else { return }
        resizeTask?.cancel()

        let target = ClaudeCodeNotch.size(for: content, notchWidth: model.notchWidth, notchHeight: model.notchHeight)
        let wasVisible = panel.isVisible && model.content != .hidden
        let current = panel.frame.size
        let grows = !wasVisible || (target.width >= current.width && target.height >= current.height)
        panel.hasShadow = content.isCard

        if grows {
            // The window grows first so the shape has room to animate into.
            panel.setFrame(ClaudeCodeNotch.frame(for: target, screenFrame: screen.frame), display: true)
            panel.orderFrontRegardless()
            if wasVisible {
                model.content = content
            } else {
                model.content = .hidden
                DispatchQueue.main.async { [weak model] in model?.content = content }
            }
        } else {
            // The shape shrinks first; the window follows once it has.
            model.content = content
            panel.orderFrontRegardless()
            resizeTask = Task { @MainActor [weak panel, weak self] in
                try? await Task.sleep(for: .seconds(NotchDesign.closeDuration))
                guard !Task.isCancelled, let panel, let screen = self?.screen else { return }
                panel.setFrame(ClaudeCodeNotch.frame(for: target, screenFrame: screen.frame), display: true)
            }
        }
    }

    /// The notched display when there is one, as for the idle tab; otherwise the usual screen,
    /// where the band hangs from the menu bar.
    private func buildPanel() {
        let notched = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        guard let screen = notched ?? RecorderScreenResolver.resolve(),
            let metrics = NotchRecorderPanel.calculateWindowMetrics(on: screen)
        else {
            logger.error("Claude Code notch not built: no screen")
            return
        }
        self.screen = screen
        let model = ClaudeCodeNotchModel(notchWidth: metrics.notchWidth, notchHeight: metrics.notchHeight)
        let size = ClaudeCodeNotch.size(for: .hidden, notchWidth: metrics.notchWidth, notchHeight: metrics.notchHeight)
        let panel = ClaudeCodeNotchPanel(contentRect: ClaudeCodeNotch.frame(for: size, screenFrame: screen.frame))
        let view = ClaudeCodeNotchView(
            model: model,
            onDecision: { [weak activity] id, decision in activity?.decide(id, decision) },
            onOffer: { turnOn in ClaudeCodeIntegration.shared.answerOffer(turnOn: turnOn) },
            onKeyboard: { [weak panel] wanted in
                guard let panel else { return }
                panel.acceptsKeyboard = wanted
                if wanted { panel.makeKey() } else { panel.resignKey() }
            })
        panel.contentView = NotchRecorderHostingController(rootView: view).view
        self.model = model
        self.panel = panel
        logger.notice(
            "Claude Code notch built notch=\(metrics.notchWidth, privacy: .public)x\(metrics.notchHeight, privacy: .public)"
        )
    }

    private func destroyPanel() {
        resizeTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
        model = nil
        screen = nil
    }
}
