import SwiftUI

// MARK: - Icon Toggle Button

struct RecorderToggleButton: View {
    let isEnabled: Bool
    let icon: String
    let disabled: Bool
    let action: () -> Void

    init(isEnabled: Bool, icon: String, disabled: Bool = false, action: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.icon = icon
        self.disabled = disabled
        self.action = action
    }

    private var isEmoji: Bool {
        !icon.contains(".") && !icon.contains("-") && icon.unicodeScalars.contains { !$0.isASCII }
    }

    var body: some View {
        Button(action: action) {
            Group {
                if isEmoji {
                    Text(icon).font(.app(size: 14, weight: .regular))
                } else {
                    Image(systemName: icon).font(.app(size: 13, weight: .regular))
                }
            }
            .foregroundColor(disabled ? Color.primary.opacity(0.3) : (isEnabled ? Color.primary : Color.primary.opacity(0.6)))
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(disabled)
    }
}

// MARK: - Record Button

struct RecorderRecordButton: View {
    let recordingState: RecordingState
    let action: () -> Void

    private var visualState: VisualState {
        switch recordingState {
        case .idle, .starting, .busy:
            return .ready
        case .recording:
            return .recording
        case .transcribing, .enhancing:
            return .processing
        }
    }

    private var isDisabled: Bool {
        switch recordingState {
        case .idle, .recording:
            return false
        case .starting, .transcribing, .enhancing, .busy:
            return true
        }
    }

    var body: some View {
        Button(action: action) {
            buttonFace
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(accessibilityLabel)
        .accessibilityLabel(Text(accessibilityLabel))
    }

    private var buttonFace: some View {
        ZStack {
            Circle()
                .fill(colors.surface)
                .overlay(
                    Circle()
                        .strokeBorder(colors.border, lineWidth: 0.6)
                )

            stateMark
        }
        .frame(width: 21, height: 21)
        .contentShape(Circle())
        .animation(.easeOut(duration: 0.16), value: visualState)
    }

    private var colors: StateColors {
        switch visualState {
        case .ready:
            return StateColors(
                surface: Color(red: 0.30, green: 0.30, blue: 0.32),
                border: Color(red: 0.42, green: 0.42, blue: 0.44),
                mark: Color(red: 0.78, green: 0.78, blue: 0.80)
            )
        case .recording:
            let red = AppTheme.Status.error
            return StateColors(
                surface: red.opacity(0.92),
                border: red.opacity(0.98),
                mark: Color.primary
            )
        case .processing:
            return StateColors(
                surface: Color.primary.opacity(0.13),
                border: Color.primary.opacity(0.18),
                mark: Color.primary.opacity(0.86)
            )
        }
    }

    @ViewBuilder
    private var stateMark: some View {
        switch visualState {
        case .ready, .recording:
            RoundedRectangle(cornerRadius: 2.2, style: .continuous)
                .fill(colors.mark)
                .frame(width: 8, height: 8)
        case .processing:
            ProcessingIndicator(color: colors.mark)
        }
    }

    private var accessibilityLabel: String {
        switch recordingState {
        case .idle:
            return String(localized: "Start recording")
        case .starting:
            return String(localized: "Starting recording")
        case .recording:
            return String(localized: "Stop recording")
        case .transcribing:
            return String(localized: "Transcribing recording")
        case .enhancing:
            return String(localized: "Enhancing recording")
        case .busy:
            return String(localized: "Recorder unavailable")
        }
    }

    private enum VisualState: Equatable {
        case ready
        case recording
        case processing
    }

    private struct StateColors {
        let surface: Color
        let border: Color
        let mark: Color
    }
}

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

// MARK: - Processing Indicator

struct ProcessingIndicator: View {
    @State private var rotation: Double = 0
    let color: Color

    var body: some View {
        Circle()
            .trim(from: 0.1, to: 0.9)
            .stroke(color, lineWidth: 1.5)
            .frame(width: 12, height: 12)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}

// MARK: - Progress Dot Animation

struct ProgressAnimation: View {
    let color: Color
    let animationSpeed: Double

    private let dotCount = 5
    private let dotSize: CGFloat = 3
    private let dotSpacing: CGFloat = 2

    @State private var currentDot = 0
    @State private var timer: Timer?

    init(color: Color = Color.primary, animationSpeed: Double = 0.3) {
        self.color = color
        self.animationSpeed = animationSpeed
    }

    var body: some View {
        HStack(spacing: dotSpacing) {
            ForEach(0..<dotCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: dotSize / 2)
                    .fill(color.opacity(index <= currentDot ? 0.85 : 0.25))
                    .frame(width: dotSize, height: dotSize)
            }
        }
        .onAppear { startAnimation() }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }

    private func startAnimation() {
        timer?.invalidate()
        currentDot = 0
        timer = Timer.scheduledTimer(withTimeInterval: animationSpeed, repeats: true) { _ in
            currentDot = (currentDot + 1) % (dotCount + 2)
            if currentDot > dotCount { currentDot = -1 }
        }
    }
}

// MARK: - Mode Button

struct RecorderModeButton: View {
    @ObservedObject private var modeManager = ModeManager.shared
    let buttonSize: CGFloat
    let padding: EdgeInsets

    @State private var isPopoverPresented = false
    @State private var isHoveringButton: Bool = false
    @State private var isHoveringPopover: Bool = false
    @State private var dismissWorkItem: DispatchWorkItem?

    init(buttonSize: CGFloat = 28, padding: EdgeInsets = EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 7)) {
        self.buttonSize = buttonSize
        self.padding = padding
    }

    var body: some View {
        RecorderToggleButton(
            isEnabled: !modeManager.enabledConfigurations.isEmpty,
            icon: modeManager.enabledConfigurations.isEmpty
                ? "square.grid.2x2" : (modeManager.currentEffectiveConfiguration?.icon.value ?? "square.grid.2x2"),
            disabled: modeManager.enabledConfigurations.isEmpty
        ) {
            isPopoverPresented.toggle()
        }
        .frame(width: buttonSize)
        .padding(padding)
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

// MARK: - Live Transcript View

struct LiveTranscriptView: View {
    let text: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                Text(text)
                    .font(.app(size: 15, weight: .regular))
                    .foregroundColor(AppTheme.Notch.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 8)
                    .id("bottom")
            }
            .frame(height: 62)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: .black, location: 0.18),
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

// MARK: - Recorder Status Display

struct RecorderStatusDisplay: View {
    let currentState: RecordingState
    let audioMeterProvider: () -> AudioMeter
    let menuBarHeight: CGFloat?

    init(
        currentState: RecordingState,
        audioMeterProvider: @escaping () -> AudioMeter,
        menuBarHeight: CGFloat? = nil
    ) {
        self.currentState = currentState
        self.audioMeterProvider = audioMeterProvider
        self.menuBarHeight = menuBarHeight
    }

    var body: some View {
        Group {
            if currentState == .enhancing {
                ProcessingStatusDisplay(mode: .enhancing, color: Color.primary).transition(.opacity)
            } else if currentState == .transcribing {
                ProcessingStatusDisplay(mode: .transcribing, color: Color.primary).transition(.opacity)
            } else if currentState == .recording {
                AudioVisualizer(
                    audioMeterProvider: audioMeterProvider,
                    color: AppTheme.Accent.primary,
                    isActive: true
                )
                    .scaleEffect(y: menuBarHeight != nil ? min(1.0, (menuBarHeight! - 8) / 25) : 1.0, anchor: .center)
                    .transition(.opacity)
            } else {
                StaticVisualizer(color: Color.primary)
                    .scaleEffect(y: menuBarHeight != nil ? min(1.0, (menuBarHeight! - 8) / 25) : 1.0, anchor: .center)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: currentState)
    }
}

// MARK: - Assistant Response Panel

struct AssistantPanelView: View {
    @ObservedObject var session: AssistantSession
    let liveFollowUpText: String
    let onSend: (String) -> Void

    @State private var draftMessage = ""
    @FocusState private var isFollowUpFieldFocused: Bool

    private let horizontalPadding: CGFloat = 22
    private let followUpTextColor = AppTheme.Notch.text

    private var statusText: String? {
        switch session.phase {
        case .responding, .sendingFollowUp:
            return String(localized: "Thinking")
        case .failed(let message):
            return message
        case .inactive, .ready:
            return nil
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            messageList
            followUpRow
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .frame(height: 300)
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
                                .font(.app(size: 14))
                                .foregroundStyle(AppTheme.Notch.textMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 56)
                    }

                    ForEach(session.messages) { message in
                        AssistantMessageBubble(message: message)
                            .id(message.id)
                    }

                    if let statusText {
                        Text(statusText)
                            .font(.app(size: 14, weight: .regular))
                            .foregroundColor(AppTheme.Notch.textMuted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("status")
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: session.messages.count) {
                scrollToBottom(proxy)
            }
            .onChange(of: session.phase) {
                scrollToBottom(proxy)
            }
        }
    }

    private var followUpRow: some View {
        HStack(spacing: 8) {
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
                        Text("Type or hold")
                        ModifierKeyHintBadge(symbol: "option")
                        ModifierKeyHintBadge(symbol: "control")
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .padding(.vertical, 9)
            .frame(minHeight: 46)
            .background(Capsule().fill(AppTheme.Notch.field))
            .overlay(Capsule().strokeBorder(LinearGradient(colors: [Color.primary.opacity(0.22), AppTheme.Notch.fieldBorder], startPoint: .top, endPoint: .bottom), lineWidth: 1))

            Button(action: sendDraftMessage) {
                Image(systemName: "arrow.up")
                    .font(.app(size: 13, weight: .bold))
                    .foregroundColor(canSendDraft ? Color(nsColor: .windowBackgroundColor) : Color.primary.opacity(0.35))
                    .frame(width: 32, height: 32)
                    .background(canSendDraft ? Color.primary.opacity(0.92) : Color.primary.opacity(0.10))
                    .clipShape(Circle())
            }
            .opacity(canSendDraft ? 1 : 0)
            .frame(width: canSendDraft ? 32 : 0)
            .buttonStyle(.plain)
            .disabled(!canSendDraft)
            .help("Send follow up")
        }
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

        return TimeAnswer(time: String(trimmed[timeRange]), meridiem: meridiem, timeZoneLabel: TimeZone.current.identifier.components(separatedBy: "/").last?.replacingOccurrences(of: "_", with: " "))
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
