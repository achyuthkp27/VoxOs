import SwiftUI

/// The bottom recorder, in the same language as the notch: a black pill holding only the
/// four-bar wave (white dictation, blue enhanced, violet Agent). Live words and agent replies
/// grow the pill upwards; nothing else is written on it.
struct MiniRecorderView<S: RecorderStateProvider & ObservableObject>: View {
    @ObservedObject var stateProvider: S
    @ObservedObject var recorder: Recorder
    @ObservedObject var assistantSession: AssistantSession
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    let onAssistantFollowUp: (String) -> Void
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true
    @ObservedObject private var modeManager = ModeManager.shared

    private let pillWidth: CGFloat = 92
    private let pillHeight: CGFloat = 40
    private let transcriptWidth: CGFloat = 440
    private let assistantWidth: CGFloat = 520

    private var hasLiveTranscript: Bool {
        showLiveTranscript && stateProvider.recordingState == .recording && !stateProvider.partialTranscript.isEmpty
    }

    private var hasAssistantResponse: Bool { assistantSession.isVisible }

    private var isExpanded: Bool { hasLiveTranscript || hasAssistantResponse }

    private var shouldShowCloseButton: Bool {
        hasAssistantResponse && stateProvider.recordingState == .idle && !assistantSession.isBusy
    }

    private var liveAssistantFollowUpText: String {
        guard showLiveTranscript, stateProvider.recordingState == .recording else { return "" }
        return stateProvider.partialTranscript
    }

    private var accent: Color { RecorderModeAccent.color(for: modeManager.currentEffectiveConfiguration) }

    private var width: CGFloat {
        hasAssistantResponse ? assistantWidth : (hasLiveTranscript ? transcriptWidth : pillWidth)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: isExpanded ? 22 : pillHeight / 2, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            if hasAssistantResponse {
                AssistantPanelView(
                    session: assistantSession,
                    liveFollowUpText: liveAssistantFollowUpText,
                    onSend: onAssistantFollowUp
                )
                .transition(.opacity)
            } else if hasLiveTranscript {
                LiveTranscriptView(text: stateProvider.partialTranscript)
                    .padding(.top, 6)
                    .transition(.opacity)
            }

            waveRow
        }
        .frame(width: width)
        .background(Color.black.clipShape(shape))
        .overlay(shape.stroke(Color.white.opacity(0.08), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .shadow(color: Color.black.opacity(0.35), radius: 14, y: 6)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: hasLiveTranscript)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: hasAssistantResponse)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var waveRow: some View {
        HStack(spacing: 10) {
            if shouldShowCloseButton {
                RecorderCloseButton(action: onCloseTapped)
                Spacer(minLength: 0)
            }
            NotchWave(
                state: stateProvider.recordingState,
                audioMeterProvider: recorder.audioMeterSnapshot,
                accent: accent
            )
            if shouldShowCloseButton {
                Spacer(minLength: 0)
                Color.clear.frame(width: 22, height: 1)
            }
        }
        .padding(.horizontal, shouldShowCloseButton ? 12 : 0)
        .frame(maxWidth: .infinity)
        .frame(height: pillHeight)
    }
}
