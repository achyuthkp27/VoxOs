import AppKit
import Combine
import SwiftUI
import os

struct ClaudeCodeNotchView: View {
    @ObservedObject var model: ClaudeCodeNotchModel
    let onDecision: (UUID, ClaudeCodeActivity.Decision) -> Void
    let onOffer: (Bool) -> Void
    let onKeyboard: (Bool) -> Void
    /// The waiting band was clicked: show the card although the terminal is in front.
    let onReveal: () -> Void
    let onSpeak: (String) -> Void
    let onDismissReply: () -> Void
    let onOpenTerminal: (pid_t) -> Void
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
                    } else if let plan = prompt.plan {
                        ClaudeCodePlanCard(prompt: prompt, plan: plan, onDecision: onDecision, onKeyboard: onKeyboard)
                    } else {
                        ClaudeCodeApprovalCard(prompt: prompt, onDecision: onDecision)
                    }
                }
                // A new request starts fresh: no answers or selection carried over from the last.
                .id(prompt.id)
                .frame(height: ClaudeCodeNotch.cardContentHeight(for: prompt), alignment: .top)
                .transition(.opacity)
            }
            if case .reply(let reply) = content {
                ClaudeCodeReplyCard(reply: reply, onSpeak: onSpeak, onDismiss: onDismissReply)
                    .id(reply.id)
                    .frame(height: ClaudeCodeNotch.replyContentHeight, alignment: .top)
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
        .onTapGesture {
            if case .waiting = content { onReveal() }
        }
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
        case .reply:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(ClaudeCodeNotch.doneColor)
                .accessibilityLabel(Text("Claude Code finished"))
        case .waiting:
            ClaudeCodeSpark(spinning: false)
                .accessibilityLabel(Text("Claude Code is waiting in its terminal. Click to answer here."))
                .accessibilityAddTraits(.isButton)
        case .approval(let prompt, _):
            ClaudeCodeSpark(spinning: false)
                .accessibilityLabel(
                    Text(
                        prompt.plan != nil
                            ? "Claude Code has a plan ready"
                            : prompt.questions == nil
                                ? "Claude Code is asking for permission" : "Claude Code is asking you")
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
        case .waiting(let count):
            Text(verbatim: "\(count)")
                .font(.appMono(size: 11, weight: .bold))
                .foregroundStyle(ClaudeCodeNotch.claudeColor)
                .accessibilityLabel(Text("\(count) waiting"))
        case .approval(_, let waiting):
            HStack(spacing: 10) {
                if waiting > 1 {
                    Text("+\(waiting - 1) waiting")
                        .font(.appMono(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .accessibilityLabel(Text("\(waiting - 1) more waiting"))
                }
                if let terminal = model.terminal {
                    ClaudeCodeTerminalButton(pid: terminal) { onOpenTerminal(terminal) }
                }
            }
        default:
            Color.clear
        }
    }

    // MARK: Material

    /// One black surface, as the music card: glass under a black notch row read as a dark strip
    /// across the top.
    @AppStorage(DefaultsKeys.notchMaterial) private var materialRaw = NotchDesign.Material.liquidGlass.rawValue

    @ViewBuilder
    private var background: some View {
        if content.isCard, NotchDesign.Material.resolve(materialRaw) == .liquidGlass {
            NotchGlassSurface(shape: shape, solidHeight: model.notchHeight, totalHeight: size.height).overlay(rim)
        } else {
            // Fully opaque for a card in Solid Black, as Notch Home's: at 98% the text of a window
            // behind showed through around the option rows.
            shape.fill(content.isCard ? Color(red: 0, green: 0, blue: 2 / 255) : NotchDesign.solid).overlay(rim)
        }
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

/// The session's terminal app, by its own icon: a click brings it to the front, where the
/// session is.
private struct ClaudeCodeTerminalButton: View {
    let pid: pid_t
    let action: () -> Void
    @State private var hovered = false

    private var app: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }

    var body: some View {
        Button(action: action) {
            Group {
                if let icon = app?.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "terminal").font(.system(size: 11, weight: .semibold))
                }
            }
            .frame(width: 16, height: 16)
            .opacity(hovered ? 1 : 0.8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(String(localized: "Open \(app?.localizedName ?? "the terminal")"))
        .accessibilityLabel(Text("Open \(app?.localizedName ?? "the terminal")"))
    }
}
