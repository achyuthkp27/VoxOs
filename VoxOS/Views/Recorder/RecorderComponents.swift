import SwiftUI

// MARK: - Close Button

struct RecorderCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(0.13))
                    .overlay(
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.6)
                    )

                Image(systemName: "xmark")
                    .font(.app(size: 9, weight: .semibold))
                    .foregroundColor(Color.primary.opacity(0.86))
            }
            .frame(width: 21, height: 21)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Close")
    }
}

// MARK: - Mode accent

enum RecorderModeAccent {
    /// White for dictation, with or without AI enhancement; violet for the Agent. Blue for
    /// enhanced dictation looked like a different product on the black band.
    static func color(for config: ModeConfig?) -> Color {
        guard let config else { return AppTheme.Notch.text }
        if config.id == StarterModeCatalog.agentId { return AppTheme.Recorder.agentAccent }
        return AppTheme.Notch.text
    }
}

// MARK: - Pill accessibility

/// What the pill is doing, said in words for VoiceOver, because the pill itself carries no text.
enum RecorderPillAccessibility {
    static func label(recordingState: RecordingState, assistantVisible: Bool, assistantBusy: Bool) -> String {
        switch recordingState {
        case .starting, .recording:
            return String(localized: "Listening")
        case .transcribing, .enhancing:
            return String(localized: "Thinking")
        case .idle, .busy:
            if assistantBusy { return String(localized: "Thinking") }
            return assistantVisible ? String(localized: "Reply") : String(localized: "Recorder")
        }
    }
}

// MARK: - Notch Wave (minimal)

/// The whole notch UI while recording: five small bars at the left edge. Colour says which
/// mode is listening (white for dictation, plain or AI-enhanced; violet for the Agent); the bars
/// breathe while transcribing or enhancing. Hover opens the mode picker.
struct NotchWave: View {
    let state: RecordingState
    let audioMeterProvider: () -> AudioMeter
    let accent: Color

    @State private var isPopoverPresented = false
    @State private var isHoveringButton = false
    @State private var isHoveringPopover = false
    @State private var dismissWorkItem: DispatchWorkItem?

    private var isProcessing: Bool { state == .transcribing || state == .enhancing || state == .starting }

    var body: some View {
        Group {
            if state == .recording {
                AudioVisualizer(
                    audioMeterProvider: audioMeterProvider, color: accent, isActive: true,
                    barCount: NotchDesign.barWeights.count, barWidth: NotchDesign.barWidth,
                    barSpacing: NotchDesign.barSpacing, minHeight: NotchDesign.barMinHeight,
                    maxHeight: NotchDesign.barMinHeight + NotchDesign.barRange * 0.92 + 1)
            } else {
                NotchWaveBars(accent: accent, isProcessing: isProcessing)
            }
        }
        .frame(width: NotchDesign.waveformWidth + 4, height: 24)
        .contentShape(Rectangle().inset(by: -6))
        .animation(.easeInOut(duration: 0.3), value: accent)
        .onHover {
            isHoveringButton = $0
            syncPopoverVisibility()
        }
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            ModePopover()
                .onHover {
                    isHoveringPopover = $0
                    syncPopoverVisibility()
                }
        }
    }

    private func syncPopoverVisibility() {
        if isHoveringButton || isHoveringPopover {
            dismissWorkItem?.cancel()
            dismissWorkItem = nil
            isPopoverPresented = true
        } else {
            dismissWorkItem?.cancel()
            let work = DispatchWorkItem { [isPopoverPresentedBinding = $isPopoverPresented] in
                isPopoverPresentedBinding.wrappedValue = false
            }
            dismissWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }
}

/// The wave's bars while it is not listening: low and dim at rest, breathing while processing.
private struct NotchWaveBars: View {
    let accent: Color
    let isProcessing: Bool
    /// Mirrors isProcessing. These bars are inserted when recording ends, with isProcessing
    /// already true, so an animation keyed on isProcessing itself never saw a change and the
    /// bars stood still. Setting this on appear as well as on change starts the breathing every
    /// time the bars come in, as AgentOrb does.
    @State private var breathe = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: NotchDesign.barSpacing) {
            ForEach(0..<NotchDesign.barWeights.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: NotchDesign.barWidth / 2)
                    .fill(accent.opacity(breathe ? 0.95 : 0.55))
                    .frame(
                        width: NotchDesign.barWidth,
                        height: breathe ? NotchDesign.barHeight(at: index) : NotchDesign.barMinHeight - 2
                    )
                    // A new value with a plain ease replaces the repeating animation, which is what
                    // stops the breathing when processing ends.
                    .animation(
                        breathe && !reduceMotion
                            ? .easeInOut(duration: 0.55).repeatForever(autoreverses: true).delay(Double(index) * 0.1)
                            : .easeOut(duration: 0.2),
                        value: breathe)
            }
        }
        .onAppear { breathe = isProcessing }
        .onChange(of: isProcessing) { _, processing in breathe = processing }
    }
}

// MARK: - Live Transcript View

struct LiveTranscriptView: View {
    let text: String
    /// Matched to the wave's leading inset in the row above so the pill reads as one column.
    var horizontalInset: CGFloat = 22
    /// The height the container reserves for this panel. It is passed in rather than repeated
    /// here because the bottom alignment below only works while the two agree.
    var panelHeight: CGFloat = 62

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                Text(text)
                    // Rounded to sit with the pill's own geometry, and a step heavier than the
                    // rest of the app because light text on black optically thins.
                    .font(.app(size: 15, weight: .medium, design: .rounded))
                    .foregroundColor(AppTheme.Notch.text)
                    .lineSpacing(3)
                    .tracking(0.2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, horizontalInset)
                    .padding(.bottom, 10)
                    // Grow downwards from the bottom. A line or two - which is most of a
                    // recording - then sits clear of the fade above instead of starting at the
                    // top of the panel where the mask would dim the line being read.
                    .frame(minHeight: panelHeight, alignment: .bottom)
                    .id("bottom")
            }
            .frame(height: panelHeight)
            // Only text that has scrolled out of the way is faded, which is all the separation
            // the wave row above needs now that there is no divider between them.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black, location: 0.22),
                        .init(color: .black, location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .onChange(of: text) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .transaction { $0.disablesAnimations = true }
    }
}

// MARK: - Assistant Response Panel

struct AssistantPanelView: View {
    @ObservedObject var session: AssistantSession
    @ObservedObject private var progress = AgentProgress.shared
    @ObservedObject private var modeManager = ModeManager.shared
    let liveFollowUpText: String
    let onSend: (String) -> Void

    @State private var draftMessage = ""
    @FocusState private var isFollowUpFieldFocused: Bool

    private let followUpTextColor = AppTheme.Notch.text
    /// The orb is the Agent's presence, and violet means Agent, so a plain Assistant mode shows no orb.
    private var isAgentMode: Bool { modeManager.currentEffectiveConfiguration?.id == StarterModeCatalog.agentId }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var statusText: String? {
        switch session.phase {
        case .responding, .sendingFollowUp:
            return progress.status ?? String(localized: "Thinking…")
        case .failed(let message):
            return message
        case .inactive, .ready:
            return nil
        }
    }

    var body: some View {
        AssistantPanelLayout {
            messageList
        } composer: {
            followUpRow
        }
        .onAppear(perform: focusFollowUpFieldIfAvailable)
        .onChange(of: session.phase) {
            focusFollowUpFieldIfAvailable()
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    if session.messages.isEmpty, statusText == nil {
                        VStack(spacing: 8) {
                            Image(systemName: "waveform.and.magnifyingglass")
                                .font(.app(size: 26, weight: .light))
                                .foregroundStyle(AppTheme.Notch.textMuted)
                            Text(shouldShowLiveFollowUpText ? "Listening…" : "Ask anything about what's on your screen")
                                .font(.app(size: 14, weight: .medium, design: .rounded))
                                .foregroundStyle(AppTheme.Notch.textMuted)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 56)
                    }

                    ForEach(session.messages) { message in
                        AssistantMessageBubble(message: message)
                            .id(message.id)
                    }

                    if AgentPendingAction.isWaitingForConfirmation, statusText == nil, session.canSendFollowUp {
                        ConfirmActionCard(
                            onConfirm: { onSend("confirm") },
                            onCancel: { onSend("cancel") }
                        )
                        .id("confirm")
                    }

                    if let statusText {
                        Text(statusText)
                            .font(.app(size: 14, weight: .medium, design: .rounded))
                            .foregroundColor(AppTheme.Notch.textMuted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("status")
                    }
                }
                .padding(.vertical, 2)
                // Messages sit a little further in than the composer, whose radius already
                // matches the band's corner at this inset.
                .padding(.horizontal, 4)
                .background(
                    GeometryReader { geometry in
                        Color.clear.preference(key: AssistantContentHeightKey.self, value: geometry.size.height)
                    }
                )
            }
            // Replaces the divider that used to sit above this panel: messages scrolling past
            // the top dissolve into the wave row rather than being cut by a line.
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black, location: 0.06),
                        .init(color: .black, location: 1.0),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .onChange(of: session.messages.count) {
                scrollToBottom(proxy)
            }
            .onChange(of: session.phase) {
                scrollToBottom(proxy)
            }
        }
    }

    private var followUpRow: some View {
        // The send button exists only while there is something to send, so the composer keeps the
        // same 12 pt inset on both sides instead of leaving the HStack's spacing as a phantom gap.
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                if isAgentMode {
                    AgentOrb(isActive: session.isBusy)
                }

                ZStack(alignment: .leading) {
                    if shouldShowLiveFollowUpText {
                        Text(liveFollowUpText)
                            .font(.app(size: 15, weight: .regular))
                            .foregroundStyle(followUpTextColor)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .allowsHitTesting(false)
                    }

                    if draftMessage.isEmpty && !shouldShowLiveFollowUpText {
                        HStack(spacing: 7) {
                            Text("Type, or hold")
                            ForEach(Array(followUpShortcutTokens.enumerated()), id: \.offset) { _, token in
                                ModifierKeyHintBadge(symbol: token)
                            }
                            Text("to speak")
                        }
                        .font(.app(size: 15, weight: .regular))
                        .foregroundStyle(AppTheme.Notch.textMuted)
                        .allowsHitTesting(false)
                    }

                    TextField("", text: $draftMessage)
                        .textFieldStyle(.plain)
                        .font(.app(size: 15, weight: .regular))
                        .foregroundStyle(followUpTextColor)
                        .tint(followUpTextColor)
                        .disabled(!session.canSendFollowUp)
                        .focused($isFollowUpFieldFocused)
                        .onSubmit(sendDraftMessage)
                        .accessibilityLabel(Text("Follow-up message"))
                }
            }
            .modifier(AgentComposerChrome())

            if canSendDraft {
                Button(action: sendDraftMessage) {
                    Image(systemName: "arrow.up")
                        .font(.app(size: 13, weight: .bold))
                        .foregroundColor(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 32, height: 32)
                        .background(Color.primary.opacity(0.92))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Send follow up")
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .animation(reduceMotion ? nil : NotchDesign.sizeAnimation, value: canSendDraft)
    }

    private var followUpShortcutTokens: [String] {
        let tokens = ShortcutStore.shortcut(for: .primaryRecording)?.displayTokens ?? []
        return tokens.isEmpty ? ["fn"] : tokens
    }

    private var shouldShowLiveFollowUpText: Bool {
        draftMessage.isEmpty && !liveFollowUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSendDraft: Bool {
        session.canSendFollowUp && !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendDraftMessage() {
        let trimmed = draftMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session.canSendFollowUp, !trimmed.isEmpty else { return }
        draftMessage = ""
        onSend(trimmed)
        focusFollowUpFieldIfAvailable()
    }

    private func focusFollowUpFieldIfAvailable() {
        guard session.canSendFollowUp else { return }
        DispatchQueue.main.async {
            isFollowUpFieldFocused = true
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                if let last = session.messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                } else {
                    proxy.scrollTo("status", anchor: .bottom)
                }
            }
        }
    }
}

private struct AssistantMessageBubble: View {
    let message: AssistantDisplayMessage
    @State private var isHovering = false

    private var isUser: Bool {
        message.role == .user
    }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
            textRow

            if !isUser, let timeAnswer = TimeAnswerParser.parse(message.content) {
                TimeAnswerWidget(answer: timeAnswer)
            }

            ForEach(message.cards) { card in
                AgentCardView(card: card)
            }
        }
    }

    private var textRow: some View {
        HStack(alignment: .center, spacing: 12) {
            MarkdownContentView(
                message.content,
                fontSize: isUser ? 16 : 15,
                foregroundColor: AppTheme.Notch.text,
                alignment: .leading
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, isUser ? 20 : 2)
        .padding(.vertical, isUser ? 14 : 2)
        .modifier(GlassIf(isUser, cornerRadius: 26, tint: AppTheme.Notch.bubble))
        .overlay(alignment: .topTrailing) {
            if !isUser, isHovering {
                CopyIconButton(textToCopy: message.content)
                    .scaleEffect(0.72)
                    .offset(x: 6, y: -2)
                    .transition(.opacity)
            }
        }
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering } }
        .help(isUser ? message.content : "")
    }
}

/// A parsed "what time is it" style answer, extracted from a short assistant reply so it can be
/// rendered as a big digital-clock widget instead of plain text — matches VoiceOS's demoed style.
private struct TimeAnswer {
    let time: String
    let meridiem: String?
    let timeZoneLabel: String?
}

private enum TimeAnswerParser {
    private static let regex = try? NSRegularExpression(
        pattern: #"\b(\d{1,2}:\d{2})\s*(AM|PM|am|pm)?\b"#
    )

    static func parse(_ content: String) -> TimeAnswer? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only treat this as a rich time answer when the reply is essentially just the time,
        // not a longer message that happens to mention a clock time in passing.
        guard trimmed.count <= 80, let regex else { return nil }

        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = regex.firstMatch(in: trimmed, range: range),
            let timeRange = Range(match.range(at: 1), in: trimmed)
        else { return nil }

        var meridiem: String?
        if match.range(at: 2).location != NSNotFound, let meridiemRange = Range(match.range(at: 2), in: trimmed) {
            meridiem = trimmed[meridiemRange].uppercased()
        }

        return TimeAnswer(
            time: String(trimmed[timeRange]), meridiem: meridiem,
            timeZoneLabel: TimeZone.current.identifier.components(separatedBy: "/").last?.replacingOccurrences(
                of: "_", with: " "))
    }
}

private struct TimeAnswerWidget: View {
    let answer: TimeAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(answer.time)
                    .font(.app(size: 34, weight: .semibold))
                    .foregroundStyle(Color.primary)
                if let meridiem = answer.meridiem {
                    Text(meridiem)
                        .font(.app(size: 13, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.6))
                }
            }
            if let timeZoneLabel = answer.timeZoneLabel {
                Text(timeZoneLabel)
                    .font(.app(size: 12, weight: .regular))
                    .foregroundStyle(Color.primary.opacity(0.5))
            }
        }
        .padding(.top, 2)
    }
}

/// Structured agent results: a file list, search links, or a screenshot thumbnail.
private struct AgentCardView: View {
    let card: AgentCard

    var body: some View {
        Group {
            switch card {
            case .files(let paths):
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(paths, id: \.self) { path in
                        row(
                            icon: "doc.fill", title: (path as NSString).lastPathComponent,
                            subtitle: ((path as NSString).deletingLastPathComponent as NSString)
                                .abbreviatingWithTildeInPath
                        ) {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                }
            case .links(let links):
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(links) { link in
                        row(icon: "link", title: link.title, subtitle: URL(string: link.url)?.host ?? link.url) {
                            if let url = URL(string: link.url) { NSWorkspace.shared.open(url) }
                        }
                    }
                }
            case .image(let path):
                if let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AppTheme.Notch.bubble))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func row(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.app(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.Accent.primary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.app(size: 13, weight: .medium)).foregroundStyle(AppTheme.Notch.text).lineLimit(1)
                    Text(subtitle).font(.app(size: 11)).foregroundStyle(AppTheme.Notch.textMuted).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward")
                    .font(.app(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.Notch.textMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Shown while an action (send a message, loosen the control mode…) waits for the user's word.
private struct ConfirmActionCard: View {
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "paperplane.circle.fill")
                .font(.app(size: 22, weight: .semibold))
                .foregroundStyle(AppTheme.Recorder.agentAccent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ready to send")
                    .font(.app(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.Notch.text)
                Text("Say “confirm” or “cancel”, or use the buttons.")
                    .font(.app(size: 12, weight: .regular))
                    .foregroundStyle(AppTheme.Notch.textMuted)
            }
            Spacer(minLength: 8)
            Button("Cancel", action: onCancel)
                .buttonStyle(.plain)
                .font(.app(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.Notch.text)
                .padding(.horizontal, 12).frame(height: 28)
                .background(Capsule().fill(AppTheme.Notch.chip))
            Button("Confirm", action: onConfirm)
                .buttonStyle(.plain)
                .font(.app(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).frame(height: 28)
                .background(Capsule().fill(AppTheme.Recorder.agentAccent))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AppTheme.Recorder.agentAccent.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(
                AppTheme.Recorder.agentAccent.opacity(0.35), lineWidth: 1))
    }
}

private struct ModifierKeyHintBadge: View {
    let symbol: String

    var body: some View {
        Text(symbol)
            .font(.app(size: 13, weight: .medium))
            .foregroundStyle(Color.primary.opacity(0.88))
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(Capsule().fill(AppTheme.Notch.chip))
    }
}

/// Applies rounded glass only when `enabled` — the user's bubble gets it, the reply does not.
private struct GlassIf: ViewModifier {
    let enabled: Bool
    let cornerRadius: CGFloat
    let tint: Color

    init(_ enabled: Bool, cornerRadius: CGFloat, tint: Color) {
        self.enabled = enabled
        self.cornerRadius = cornerRadius
        self.tint = tint
    }

    func body(content: Content) -> some View {
        if enabled {
            content.background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(tint))
        } else {
            content
        }
    }
}
