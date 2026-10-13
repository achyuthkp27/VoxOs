import SwiftUI

struct NotchRecorderView<S: RecorderStateProvider & ObservableObject>: View {
    @ObservedObject var stateProvider: S
    @ObservedObject var recorder: Recorder
    @ObservedObject var assistantSession: AssistantSession
    @ObservedObject private var modeManager = ModeManager.shared
    let onRecordButtonTapped: () -> Void
    let onCloseTapped: () -> Void
    let onAssistantFollowUp: (String) -> Void
    /// The notch of the screen the window was built on. Resolving the screen per render follows
    /// the key window, which moves the band to another display after a click there.
    var notchMetricsOverride: (width: CGFloat, height: CGFloat)? = nil
    /// Reports the band's laid-out size, so the window manager can tell a click on the band from a
    /// click on the transparent rest of its much larger window.
    var onPillSizeChange: (CGSize) -> Void = { _ in }
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true
    @AppStorage(DefaultsKeys.notchMaterial) private var notchMaterialRaw = NotchDesign.Material.liquidGlass.rawValue
    /// Bumped on every screen reconfiguration to invalidate the view. The notch metrics below
    /// come from AppKit, which SwiftUI cannot observe on its own, so without this the view keeps
    /// whatever sizes it happened to compute the last time it was rendered.
    @State private var screenGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        if let notchMetricsOverride { return notchMetricsOverride }

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
            return NotchDesign.fallbackNotchHeight
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
    /// Follows the messages: a one-line answer gets a short panel, a long one the full height.
    @State private var assistantContentHeight: CGFloat = 0
    private var assistantPanelHeight: CGFloat { AgentComposer.panelHeight(forContent: assistantContentHeight) }

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
        .animation(reduceMotion ? nil : pillAnimation, value: displayState)
        // The panel height follows the reply; the band must resize with it, not snap.
        .animation(reduceMotion ? nil : NotchDesign.sizeAnimation, value: assistantPanelHeight)
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
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: onPillSizeChange)
        .background(notchBackground)
        .environment(\.colorScheme, .dark)
        // One shadow for the whole band, not one per layer.
        .compositingGroup()
        .shadow(
            color: Color.black.opacity(activeShadow.opacity), radius: activeShadow.radius, y: activeShadow.y
        )
        .animation(.easeInOut(duration: 0.35), value: isRecording)
        .animation(.easeInOut(duration: 0.35), value: isAgentMode)
    }

    // MARK: - Material

    private var notchMaterial: NotchDesign.Material { NotchDesign.Material.resolve(notchMaterialRaw) }

    @ViewBuilder
    private var notchBackground: some View {
        switch notchMaterial {
        case .solidBlack: solidBackground
        case .liquidGlass: glassBackground
        }
    }

    /// Near-black, faint sheen from the top, cool rim on the lower edge once it is active.
    private var solidBackground: some View {
        notchShape.fill(NotchDesign.solid)
            .overlay(
                notchShape.fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.035), .clear], startPoint: .top,
                        endPoint: UnitPoint(x: 0.5, y: 0.6)))
            )
            .overlay(rim)
    }

    /// Real Liquid Glass below, solid black above. The top stays black so the band reads as part of
    /// the physical notch, and fades into glass a little under halfway down.
    private var glassBackground: some View {
        ZStack {
            notchShape.fill(NotchDesign.glassUnderlay)
                .liquidGlass(in: notchShape, tint: NotchDesign.glassTint)
            notchShape.fill(NotchDesign.solid)
                .mask(
                    LinearGradient(
                        stops: [
                            // Solid for the full height of the hardware notch, glass only below it.
                            .init(color: .white, location: 0),
                            .init(color: .white, location: min(1, notchHeight / max(pillHeight, 1))),
                            .init(color: .clear, location: min(1, (notchHeight + 12) / max(pillHeight, 1))),
                        ], startPoint: .top, endPoint: .bottom))
            rim
        }
    }

    private var rim: some View {
        notchShape.stroke(NotchDesign.rim, lineWidth: NotchDesign.rimWidth)
            .mask(
                LinearGradient(
                    colors: [.clear, .white], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35))
            )
            .opacity(displayState == .collapsed ? 0 : 1)
    }

    private var isRecording: Bool { stateProvider.recordingState == .recording }

    private var isAgentMode: Bool { modeManager.currentEffectiveConfiguration?.id == StarterModeCatalog.agentId }

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
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(pillAccessibilityLabel))
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

    /// Mode colour for the wave: white for dictation (plain or AI-enhanced), violet for the Agent.
    private var modeAccent: Color {
        RecorderModeAccent.color(for: modeManager.currentEffectiveConfiguration)
    }

    private var pillAccessibilityLabel: String {
        RecorderPillAccessibility.label(
            recordingState: stateProvider.recordingState, assistantVisible: assistantSession.isVisible,
            assistantBusy: assistantSession.isBusy)
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
                .onPreferenceChange(AssistantContentHeightKey.self) { assistantContentHeight = $0 }
            }
        }
        .frame(height: displayState == .assistant ? assistantPanelHeight : 0)
        .animation(reduceMotion ? nil : NotchDesign.sizeAnimation, value: assistantContentHeight)
        .clipped()
    }
}
