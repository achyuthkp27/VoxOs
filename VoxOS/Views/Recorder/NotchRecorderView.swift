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
    private var assistantSideExpansion: CGFloat { max(140, (NotchDesign.expandedWidth - notchWidth) / 2) }
    /// The listening band is exactly as tall as the notch: it widens out of it instead of hanging down.
    private let activeHeightBonus: CGFloat = 0
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

    /// Content starts a comfortable distance inside the straight side of the band, which begins one
    /// shoulder-radius in from the frame edge. A fixed inset would crowd the scoop as it grows.
    private var sideEdgePadding: CGFloat {
        notchShape.topCornerRadius + NotchDesign.contentInset
    }

    private var shouldShowCloseButton: Bool {
        displayState == .assistant && stateProvider.recordingState == .idle && !assistantSession.isBusy
    }

    private var liveAssistantFollowUpText: String {
        guard showLiveTranscript, stateProvider.recordingState == .recording else { return "" }
        return stateProvider.partialTranscript
    }

    // MARK: - Animation

    private let expandAnimation = NotchDesign.openAnimation
    private let collapseAnimation = NotchDesign.closeAnimation

    /// Opening is quick and snappy, closing is short, and growing between open states is one calm ease.
    private var pillAnimation: Animation {
        switch displayState {
        case .collapsed: return NotchDesign.closeAnimation
        case .active: return NotchDesign.openAnimation
        case .liveText, .assistant: return NotchDesign.sizeAnimation
        }
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
        // Near-black glass: solid enough to read as part of the physical notch, with a faint sheen
        // from the top and a cool one-point rim on the lower edge once it is doing something.
        .background(
            notchShape.fill(NotchDesign.solid)
                .overlay(
                    notchShape.fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.035), .clear], startPoint: .top,
                            endPoint: UnitPoint(x: 0.5, y: 0.6)))
                )
                .overlay(
                    notchShape.stroke(NotchDesign.rim, lineWidth: NotchDesign.rimWidth)
                        .mask(
                            LinearGradient(
                                colors: [.clear, .white], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35))
                        )
                        .opacity(displayState == .collapsed ? 0 : 1)
                )
        )
        .environment(\.colorScheme, .dark)
        .shadow(
            color: Color.black.opacity(activeShadow.opacity), radius: activeShadow.radius, y: activeShadow.y
        )
        .animation(.easeInOut(duration: 0.35), value: isRecording)
        .animation(.easeInOut(duration: 0.35), value: isAgentMode)
    }

    private var isRecording: Bool { stateProvider.recordingState == .recording }

    private var isAgentMode: Bool { modeManager.currentEffectiveConfiguration?.id == StarterModeCatalog.agentId }

    private var recordingAccent: Color { isAgentMode ? AppTheme.Recorder.agentAccent : AppTheme.Accent.primary }

    private var activeShadow: NotchDesign.Shadow {
        displayState == .collapsed ? NotchDesign.restingShadow : NotchDesign.activeShadow
    }

    /// Corners grow with the surface: resting, listening, expanded.
    private var notchShape: NotchShape {
        switch displayState {
        case .collapsed: return NotchShape(NotchDesign.resting)
        case .active, .liveText: return NotchShape(NotchDesign.listening)
        case .assistant: return NotchShape(NotchDesign.expanded)
        }
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
        RecorderModeAccent.color(for: modeManager.currentEffectiveConfiguration)
    }

    // MARK: - Live Text Panel

    /// No rule between the wave and the transcript: the pill is one continuous black surface,
    /// and `LiveTranscriptView` fades its own top edge so new text rises out of the row above.
    private var liveTextPanel: some View {
        VStack(spacing: 0) {
            if displayState == .liveText {
                LiveTranscriptView(
                    text: stateProvider.partialTranscript,
                    horizontalInset: sideEdgePadding,
                    panelHeight: transcriptPanelHeight
                )
            }
        }
        .frame(height: displayState == .liveText ? transcriptPanelHeight : 0)
        .clipped()
    }

    /// Like `liveTextPanel`: no rule under the wave row. The message list fades its own top edge.
    private var assistantPanel: some View {
        VStack(spacing: 0) {
            if displayState == .assistant {
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
