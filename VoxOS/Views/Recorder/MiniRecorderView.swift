import SwiftUI

/// The HUD recorder: a floating glass panel at the bottom-centre of the screen. One row of
/// state (mode, what VoxOS is doing, waveform, elapsed time), the live words underneath,
/// and the agent conversation when there is one.
struct MiniRecorderView<S: RecorderStateProvider & ObservableObject>: View {
    @ObservedObject var stateProvider: S
    @ObservedObject var recorder: Recorder
    @ObservedObject var assistantSession: AssistantSession
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    let onAssistantFollowUp: (String) -> Void
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true
    @ObservedObject private var modeManager = ModeManager.shared
    @State private var recordingStartedAt: Date?

    private let panelWidth: CGFloat = 580
    private let cornerRadius: CGFloat = 26

    // MARK: - Derived state

    private var isRecording: Bool { stateProvider.recordingState == .recording }
    private var isAgentMode: Bool { modeManager.currentEffectiveConfiguration?.id == StarterModeCatalog.agentId }
    private var accent: Color { isAgentMode ? AppTheme.Recorder.agentAccent : AppTheme.Accent.primary }

    private var hasLiveTranscript: Bool {
        showLiveTranscript && isRecording && !stateProvider.partialTranscript.isEmpty
    }

    private var hasAssistantResponse: Bool { assistantSession.isVisible }

    private var shouldShowCloseButton: Bool {
        hasAssistantResponse && stateProvider.recordingState == .idle && !assistantSession.isBusy
    }

    private var liveAssistantFollowUpText: String {
        guard showLiveTranscript, isRecording else { return "" }
        return stateProvider.partialTranscript
    }

    private var statusLine: LocalizedStringKey {
        switch stateProvider.recordingState {
        case .recording:
            return isAgentMode ? "Listening — sends when you pause" : "Listening"
        case .transcribing: return "Transcribing"
        case .enhancing: return isAgentMode ? "Working on it" : "Polishing"
        case .starting: return "Starting"
        case .busy: return "Busy"
        case .idle: return hasAssistantResponse ? "" : "Ready"
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, hasLiveTranscript || hasAssistantResponse ? 8 : 14)

            if hasAssistantResponse {
                Divider().overlay(Color.primary.opacity(0.10))
                AssistantPanelView(
                    session: assistantSession,
                    liveFollowUpText: liveAssistantFollowUpText,
                    onSend: onAssistantFollowUp
                )
            } else if hasLiveTranscript {
                liveWords
                    .padding(.horizontal, 22)
                    .padding(.bottom, 18)
            }
        }
        .frame(width: panelWidth)
        .liquidGlass(cornerRadius: cornerRadius, tint: isRecording ? accent.opacity(0.10) : nil)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    LinearGradient(colors: [Color.primary.opacity(0.22), AppTheme.Notch.rim.opacity(0.4)], startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
        )
        .shadow(color: isRecording ? accent.opacity(0.35) : Color.black.opacity(0.28), radius: isRecording ? 28 : 18, y: 10)
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: hasLiveTranscript)
        .animation(.spring(response: 0.38, dampingFraction: 0.85), value: hasAssistantResponse)
        .animation(.easeInOut(duration: 0.3), value: isRecording)
        .animation(.easeInOut(duration: 0.3), value: isAgentMode)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onChange(of: stateProvider.recordingState, initial: true) { _, state in
            if state == .recording {
                if recordingStartedAt == nil { recordingStartedAt = Date() }
            } else {
                recordingStartedAt = nil
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            if shouldShowCloseButton {
                RecorderCloseButton(action: onCloseTapped)
            }
            RecorderModeChip()

            Text(statusLine)
                .font(.app(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.Notch.textMuted)
                .lineLimit(1)
                .contentTransition(.opacity)

            Spacer(minLength: 8)

            if isRecording, let start = recordingStartedAt {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    Text(Self.elapsed(from: start, to: context.date))
                        .font(.app(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(AppTheme.Notch.textMuted)
                }
            }

            RecorderStatusDisplay(
                currentState: stateProvider.recordingState,
                audioMeterProvider: recorder.audioMeterSnapshot,
                accent: accent
            )
        }
        .frame(height: 30)
    }

    private var liveWords: some View {
        Text(stateProvider.partialTranscript)
            .font(.app(size: 19, weight: .medium))
            .foregroundStyle(AppTheme.Notch.text)
            .lineLimit(3)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transaction { $0.disablesAnimations = true }
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
