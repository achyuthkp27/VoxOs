import AppKit
import Combine
import SwiftUI
import os

/// Asked once: turn the integration on from the notch itself.
struct ClaudeCodeOfferCard: View {
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
struct ClaudeCodeApprovalCard: View {
    typealias Card = ClaudeCodeNotch.Card
    let prompt: ClaudeCodeActivity.PermissionPrompt
    let onDecision: (UUID, ClaudeCodeActivity.Decision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Card.spacing) {
            ClaudeCodeEyebrow(text: ClaudeCodeNotch.eyebrowParts(for: prompt).joined(separator: " · "))

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

            if let diff = prompt.diff, !diff.isEmpty {
                ClaudeCodeDiffBox(lines: diff)
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

/// Claude's last message of a turn, to read or hear; it goes by itself after a few seconds.
struct ClaudeCodeReplyCard: View {
    typealias Card = ClaudeCodeNotch.Card
    let reply: ClaudeCodeActivity.Reply
    let onSpeak: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Card.spacing) {
            ClaudeCodeEyebrow(
                text: ([reply.project] + [reply.branch, reply.sessionTitle].compactMap { $0 }.filter { !$0.isEmpty })
                    .joined(separator: " · "))
            ScrollView(.vertical) {
                Text(ClaudeCodeNotch.planText(reply.text))
                    .font(.app(size: 12))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: CGFloat(ClaudeCodeNotch.replyLines) * Card.planLineHeight)
            .padding(.horizontal, 10)
            .padding(.vertical, Card.detailPadding)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.07)))

            HStack(spacing: 4) {
                ClaudeCodeQuietButton(title: String(localized: "Read aloud"), help: String(localized: "Hear the reply"))
                {
                    onSpeak(reply.text)
                }
                Spacer(minLength: 8)
                ClaudeCodeNotchButton(title: String(localized: "Done"), prominent: false, action: onDismiss)
            }
            .padding(.top, Card.buttonGap - Card.spacing)
        }
        .padding(.top, Card.top)
        .padding(.horizontal, AgentComposer.panelInset)
        .padding(.bottom, Card.bottom)
    }
}

/// The change an Edit or Write would make, removed lines red and added green, scrolling once
/// it is taller than the box.
private struct ClaudeCodeDiffBox: View {
    typealias Card = ClaudeCodeNotch.Card
    let lines: [ClaudeCodeDiff.Line]

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(verbatim: line.marker + " " + line.text)
                        .font(.appMono(size: 11, weight: .regular))
                        .foregroundStyle(color(line.kind))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: Card.diffLineHeight)
                        .padding(.horizontal, 8)
                        .background(fill(line.kind))
                }
            }
        }
        .scrollIndicators(.automatic)
        .frame(height: CGFloat(Swift.min(lines.count, Card.diffLines)) * Card.diffLineHeight)
        .padding(.vertical, Card.diffPadding)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.05)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Change: \(lines.count) lines"))
    }

    private func color(_ kind: ClaudeCodeDiff.Line.Kind) -> Color {
        switch kind {
        case .removed: return ClaudeCodeNotch.failedColor
        case .added: return ClaudeCodeNotch.doneColor
        case .note: return .white.opacity(0.45)
        }
    }

    private func fill(_ kind: ClaudeCodeDiff.Line.Kind) -> Color {
        switch kind {
        case .removed: return ClaudeCodeNotch.failedColor.opacity(0.1)
        case .added: return ClaudeCodeNotch.doneColor.opacity(0.1)
        case .note: return .clear
        }
    }
}

/// ExitPlanMode: the plan to read, and the plan dialog's answers. "Keep planning" turns the
/// buttons into a field for what to change, as the terminal's "No, keep planning" does.
struct ClaudeCodePlanCard: View {
    typealias Card = ClaudeCodeNotch.Card
    let prompt: ClaudeCodeActivity.PermissionPrompt
    let plan: String
    let onDecision: (UUID, ClaudeCodeActivity.Decision) -> Void
    let onKeyboard: (Bool) -> Void
    @State private var revising = false
    @State private var feedback = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Card.spacing) {
            ClaudeCodeEyebrow(text: ClaudeCodeNotch.eyebrowParts(for: prompt).joined(separator: " · "))

            Text("Approve the plan?")
                .font(.app(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(height: Card.titleLineHeight)

            planBox

            Group {
                if revising { feedbackRow } else { buttons }
            }
            .padding(.top, Card.buttonGap - Card.spacing)
        }
        .padding(.top, Card.top)
        .padding(.horizontal, AgentComposer.panelInset)
        .padding(.bottom, Card.bottom)
    }

    private var planBox: some View {
        Group {
            if plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("The plan is in the terminal.")
                    .font(.app(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView(.vertical) {
                    Text(ClaudeCodeNotch.planText(plan))
                        .font(.app(size: 12))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineSpacing(2)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(height: CGFloat(Card.planLines) * Card.planLineHeight)
        .padding(.horizontal, 10)
        .padding(.vertical, Card.detailPadding)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.white.opacity(0.07)))
    }

    private var buttons: some View {
        HStack(spacing: 4) {
            ClaudeCodeQuietButton(
                title: String(localized: "Auto-accept edits"),
                help: String(localized: "Approve, and accept edits without asking for the rest of this session")
            ) {
                onDecision(prompt.id, .approvePlan(acceptEdits: true))
            }
            Spacer(minLength: 8)
            ClaudeCodeNotchButton(title: String(localized: "Keep planning"), prominent: false) {
                revising = true
            }
            .padding(.trailing, 4)
            ClaudeCodeNotchButton(title: String(localized: "Approve"), prominent: true) {
                onDecision(prompt.id, .approvePlan(acceptEdits: false))
            }
        }
    }

    /// What to change; sent empty, Claude is only told to keep planning.
    private var feedbackRow: some View {
        HStack(spacing: 8) {
            TextField(String(localized: "What should change?"), text: $feedback)
                .textFieldStyle(.plain)
                .font(.app(size: 13))
                .foregroundStyle(.white)
                .focused($fieldFocused)
                .onSubmit(send)
                .onExitCommand(perform: stopRevising)
            ClaudeCodeNotchButton(title: String(localized: "Send"), prominent: true, action: send)
        }
        .padding(.leading, 12)
        .padding(.trailing, 0)
        .frame(height: Card.buttonHeight)
        .background(
            Capsule().strokeBorder(AppTheme.Accent.primary.opacity(0.7), lineWidth: 1)
        )
        .onAppear(perform: takeKeyboard)
        // Answered in the terminal while typing here: the panel gives the keyboard back.
        .onDisappear { onKeyboard(false) }
    }

    private func send() {
        let text = feedback
        stopRevising()
        onDecision(prompt.id, .keepPlanning(text))
    }

    /// The panel becomes key only once the field exists, and the field takes focus a run-loop
    /// turn later: focus asked for earlier went to the window's first key view (measured: with
    /// keyboard navigation on, the Send button, which a typed space then pressed).
    private func takeKeyboard() {
        onKeyboard(true)
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func stopRevising() {
        revising = false
        feedback = ""
        fieldFocused = false
        onKeyboard(false)
    }
}

/// AskUserQuestion: one question at a time. A tap answers a single-choice question (and moves
/// to the next one); a multiple-choice question collects ticks and is sent with the button.
struct ClaudeCodeQuestionCard: View {
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
        .onAppear(perform: takeKeyboard)
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

    /// See ClaudeCodePlanCard.takeKeyboard.
    private func takeKeyboard() {
        onKeyboard(true)
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func stopTyping() {
        typing = false
        typed = ""
        fieldFocused = false
        onKeyboard(false)
    }

    private var eyebrow: String {
        var parts = ClaudeCodeNotch.eyebrowParts(for: prompt)
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
