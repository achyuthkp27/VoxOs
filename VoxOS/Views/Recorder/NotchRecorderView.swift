import SwiftUI

struct NotchRecorderView<S: RecorderStateProvider & ObservableObject>: View {
    @ObservedObject var stateProvider: S
    @ObservedObject var recorder: Recorder
    @ObservedObject var assistantSession: AssistantSession
    @ObservedObject private var modeManager = ModeManager.shared
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    let onAssistantFollowUp: (String) -> Void
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true
    /// Bumped on every screen reconfiguration to invalidate the view. The notch metrics below
    /// come from AppKit, which SwiftUI cannot observe on its own, so without this the view keeps
    /// whatever sizes it happened to compute the last time it was rendered.
    @State private var screenGeneration = 0

    // MARK: - Display State

    private enum DisplayState: Equatable {
        case collapsed
        case active
        case liveText
        case assistant
    }

    private var displayState: DisplayState {
        if assistantSession.isVisible {
            return .assistant
        }

        switch stateProvider.recordingState {
        case .recording:
            let shouldShowLive = showLiveTranscript && !stateProvider.partialTranscript.isEmpty
            return shouldShowLive ? .liveText : .active
        case .transcribing, .enhancing:
            return .active
        default:
            return .collapsed
        }
    }

    // MARK: - Screen Geometry

    /// Reads `screenGeneration` so SwiftUI records a dependency on it: the metrics below come
    /// from AppKit, which it cannot observe, and a view only re-evaluates the parts that depend
    /// on the state that changed.
    private var screenMetrics: (width: CGFloat, height: CGFloat) {
        _ = screenGeneration

        guard let screen = RecorderScreenResolver.resolve() else { return (180, 37) }

        let width: CGFloat = {
            if let left = screen.auxiliaryTopLeftArea?.width,
                let right = screen.auxiliaryTopRightArea?.width
            {
                return screen.frame.width - left - right
            }
            return 180
        }()

        let height: CGFloat = {
            if screen.safeAreaInsets.top > 0 { return screen.safeAreaInsets.top }
            return NSApplication.shared.mainMenu?.menuBarHeight ?? NSStatusBar.system.thickness
        }()

        return (width, height)
    }

    private var notchWidth: CGFloat { screenMetrics.width }

    private var notchHeight: CGFloat { screenMetrics.height }

    // MARK: - Layout Constants

    private let recordingSideExpansion: CGFloat = 64
    private let transcriptSideExpansion: CGFloat = 130
    private let assistantSideExpansion: CGFloat = 140
    private let activeHeightBonus: CGFloat = 10
    private let transcriptPanelHeight: CGFloat = 64
    private let assistantPanelHeight: CGFloat = 300

    private var mainRowHeight: CGFloat { notchHeight + activeHeightBonus }

    // MARK: - Pill Dimensions

    private var pillWidth: CGFloat {
        switch displayState {
        case .collapsed: return notchWidth
        case .active: return notchWidth + recordingSideExpansion * 2
        case .liveText: return notchWidth + transcriptSideExpansion * 2
        case .assistant: return notchWidth + assistantSideExpansion * 2
        }
    }

    private var pillHeight: CGFloat {
        switch displayState {
        case .collapsed: return 0
        case .active: return mainRowHeight
        case .liveText: return mainRowHeight + transcriptPanelHeight
        case .assistant: return mainRowHeight + assistantPanelHeight
        }
    }

    private var sideExpansion: CGFloat {
        switch displayState {
        case .liveText:
            return transcriptSideExpansion
        case .assistant:
            return assistantSideExpansion
        case .active, .collapsed:
            return recordingSideExpansion
        }
    }

    private var sideEdgePadding: CGFloat {
        displayState == .liveText || displayState == .assistant ? 22 : 18
    }

    private var shouldShowCloseButton: Bool {
        displayState == .assistant && stateProvider.recordingState == .idle && !assistantSession.isBusy
    }

    private var liveAssistantFollowUpText: String {
        guard showLiveTranscript, stateProvider.recordingState == .recording else { return "" }
        return stateProvider.partialTranscript
    }

    // MARK: - Animation

    private let expandAnimation = Animation.spring(response: 0.42, dampingFraction: 0.80)
    private let collapseAnimation = Animation.spring(response: 0.45, dampingFraction: 1.0)

    private var pillAnimation: Animation {
        displayState == .collapsed ? collapseAnimation : expandAnimation
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            pill.position(x: geo.size.width / 2, y: pillHeight / 2)
        }
        .animation(pillAnimation, value: displayState)
        .onReceive(
            LifecycleObserver.shared.publisher(for: .screenConfigurationChanged)
        ) { _ in
            screenGeneration += 1
        }
    }

    // MARK: - Pill

    private var pill: some View {
        VStack(spacing: 0) {
            mainRow
            liveTextPanel
            assistantPanel
        }
        .frame(width: pillWidth, height: pillHeight)
        // Solid black so the pill reads as part of the physical notch. Forced dark appearance
        // keeps the system label colours white on it in light mode.
        .background(Color.black.clipShape(notchShape))
        .environment(\.colorScheme, .dark)
        .shadow(color: Color.black.opacity(0.35), radius: 10, y: 4)
        .animation(.easeInOut(duration: 0.35), value: isRecording)
        .animation(.easeInOut(duration: 0.35), value: isAgentMode)
    }

    private var isRecording: Bool { stateProvider.recordingState == .recording }

    private var isAgentMode: Bool { modeManager.currentEffectiveConfiguration?.id == StarterModeCatalog.agentId }

    private var recordingAccent: Color { isAgentMode ? AppTheme.Recorder.agentAccent : AppTheme.Accent.primary }

    private var notchShape: NotchShape {
        NotchShape(
            topCornerRadius: 10,
            bottomCornerRadius: displayState == .active ? 22 : AppTheme.Notch.cornerRadius
        )
    }

    // MARK: - Main Row

    private var mainRow: some View {
        ZStack {
            Color.clear

            HStack(spacing: 10) {
                if shouldShowCloseButton {
                    RecorderCloseButton(action: onCloseTapped)
                }
                NotchWave(
                    state: stateProvider.recordingState,
                    audioMeterProvider: recorder.audioMeterSnapshot,
                    accent: modeAccent
                )
                Spacer(minLength: 0)
            }
            .padding(.leading, sideEdgePadding)
            .frame(width: sideExpansion)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(displayState != .collapsed ? 1 : 0)
            .animation(
                displayState != .collapsed ? expandAnimation.delay(0.09) : collapseAnimation,
                value: displayState
            )
        }
        .frame(height: mainRowHeight)
    }

    /// Mode colour for the wave: dictation white, AI-enhanced dictation blue, Agent violet.
    private var modeAccent: Color {
        guard let config = modeManager.currentEffectiveConfiguration else { return AppTheme.Notch.text }
        if config.id == StarterModeCatalog.agentId { return AppTheme.Recorder.agentAccent }
        return config.isAIEnhancementEnabled ? AppTheme.Accent.primary : AppTheme.Notch.text
    }

    // MARK: - Live Text Panel

    private var liveTextPanel: some View {
        VStack(spacing: 0) {
            if displayState == .liveText {
                Divider().overlay(Color.primary.opacity(0.10))
                LiveTranscriptView(text: stateProvider.partialTranscript)
                    .padding(.horizontal, 8)
            }
        }
        .frame(height: displayState == .liveText ? transcriptPanelHeight : 0)
        .clipped()
    }

    private var assistantPanel: some View {
        VStack(spacing: 0) {
            if displayState == .assistant {
                Divider().overlay(Color.primary.opacity(0.10))
                AssistantPanelView(
                    session: assistantSession,
                    liveFollowUpText: liveAssistantFollowUpText,
                    onSend: onAssistantFollowUp
                )
            }
        }
        .frame(height: displayState == .assistant ? assistantPanelHeight : 0)
        .clipped()
    }
}
