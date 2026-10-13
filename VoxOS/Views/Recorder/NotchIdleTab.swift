import AppKit
import Combine
import SwiftUI
import os

/// The resting notch tab: a slim lip under the physical notch that is always there, grows when
/// the pointer reaches it, and starts a recording when clicked.
///
/// The recorder panel is built per dictation and torn down afterwards, so between dictations the
/// notch is bare. The tab is a separate, persistent panel kept deliberately tiny, and it hides
/// whenever the recorder panel is up so the two never overlap. It uses no global event monitors:
/// hover comes from the panel's own tracking, so idle cost is one small window and nothing else.
enum NotchIdleTab {
    /// How far the lip hangs below the notch at rest: enough to read as a tab, not a bar.
    static let restHeight: CGFloat = 5.5
    /// On hover the tab grows down to make room for the mode glyph and widens past the notch.
    static let hoverGrow: CGFloat = 6
    static let hoverWiden: CGFloat = 16
    static let contentHeight: CGFloat = 29
    /// At rest the lip is too short for the recorder's corners; small radii keep it a flat tab.
    static let restRadii = NotchDesign.Radii(shoulder: 8, bottom: 5)
    /// The tab waits this long after the pointer leaves before shrinking, so it never flickers.
    static let shrinkDelay: TimeInterval = 0.22

    struct Geometry: Equatable {
        let width: CGFloat
        let height: CGFloat
    }

    /// Size of the part that hangs below the notch.
    static func geometry(hovered: Bool, notchWidth: CGFloat) -> Geometry {
        hovered
            ? Geometry(width: notchWidth + hoverWiden * 2, height: restHeight + hoverGrow + contentHeight)
            : Geometry(width: notchWidth, height: restHeight)
    }

    /// The window is exactly the drawn shape: the notch's own height (covered by the hardware)
    /// plus the lip, centred on the notch. A larger window would swallow clicks on the menu bar.
    static func frame(for geometry: Geometry, notchHeight: CGFloat, screenFrame: CGRect) -> CGRect {
        let height = notchHeight + geometry.height
        return CGRect(
            x: screenFrame.midX - geometry.width / 2, y: screenFrame.maxY - height, width: geometry.width,
            height: height)
    }

    /// The tab shows only when it adds something: the notch style is in use, the setting is on,
    /// the display has a physical notch to hang from, and the recorder panel is not already up.
    static func shouldShow(enabled: Bool, style: RecorderPanelStyle, hasNotch: Bool, recorderPanelVisible: Bool)
        -> Bool
    {
        enabled && style == .notch && hasNotch && !recorderPanelVisible
    }

    /// Off unless asked for: the notch should appear on the shortcut, not whenever the pointer
    /// wanders to the top of the screen.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: DefaultsKeys.notchIdleTabEnabled) as? Bool ?? false
    }
}

// MARK: - View

struct NotchIdleTabView: View {
    let notchWidth: CGFloat
    let notchHeight: CGFloat
    let onHoverChange: (Bool) -> Void
    let onTap: () -> Void
    @ObservedObject private var modeManager = ModeManager.shared
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var geometry: NotchIdleTab.Geometry { NotchIdleTab.geometry(hovered: hovered, notchWidth: notchWidth) }
    private var shape: NotchShape { NotchShape(hovered ? NotchDesign.listening : NotchIdleTab.restRadii) }
    private var accent: Color { RecorderModeAccent.color(for: modeManager.currentEffectiveConfiguration) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            shape.fill(NotchDesign.solid)
                .overlay(
                    shape.stroke(NotchDesign.rim, lineWidth: NotchDesign.rimWidth)
                        .mask(
                            LinearGradient(
                                colors: [.clear, .white], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.4))
                        )
                        .opacity(hovered ? 1 : 0)
                )

            // The mode glyph sits in the left wing of the row below the notch, like the wave while recording.
            HStack(spacing: NotchDesign.barSpacing) {
                ForEach(0..<NotchDesign.barWeights.count, id: \.self) { index in
                    RoundedRectangle(cornerRadius: NotchDesign.barWidth / 2)
                        .fill(accent.opacity(0.9))
                        .frame(width: NotchDesign.barWidth, height: NotchDesign.barHeight(at: index))
                }
            }
            .padding(.leading, shape.topCornerRadius + NotchDesign.contentInset)
            .frame(height: NotchIdleTab.contentHeight)
            .offset(y: notchHeight + NotchIdleTab.restHeight + NotchIdleTab.hoverGrow)
            .opacity(hovered ? 1 : 0)
        }
        .frame(width: geometry.width, height: notchHeight + geometry.height, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .environment(\.colorScheme, .dark)
        .animation(
            reduceMotion ? nil : (hovered ? NotchDesign.openAnimation : NotchDesign.closeAnimation), value: hovered
        )
        .onHover { inside in
            hovered = inside
            onHoverChange(inside)
        }
        .onTapGesture(perform: onTap)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Start recording"))
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Panel

final class NotchIdleTabPanel: NSPanel {
    // Never key: the tab must not take focus from the app the user is typing into.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect, styleMask: [.nonactivatingPanel, .fullSizeContentView, .hudWindow],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        canHide = false
        level = .statusBar + 1
        backgroundColor = .clear
        isOpaque = false
        // No shadow at rest: on a 5 pt lip it reads as a halo. It is switched on while hovered.
        hasShadow = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        styleMask.remove(.titled)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovable = false
    }
}

// MARK: - Manager

/// Owns the persistent tab panel and decides when it is on screen.
@MainActor
final class NotchIdleTabManager {
    private weak var uiManager: RecorderUIManager?
    private var panel: NotchIdleTabPanel?
    private var cancellables: Set<AnyCancellable> = []
    private var shrinkTask: Task<Void, Never>?
    private var notchWidth: CGFloat = 0
    private var notchHeight: CGFloat = 0
    /// The screen the panel was sized for. Frames always come from it, never from whichever screen
    /// happens to hold the key window, so a hover cannot teleport the tab to another display.
    private var screen: NSScreen?
    private var hovered = false
    private var enabledLastSeen = NotchIdleTab.isEnabled
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "NotchIdleTab")

    init(uiManager: RecorderUIManager) {
        self.uiManager = uiManager

        uiManager.$isRecorderPanelVisible.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        uiManager.$recorderPanelStyle.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // Only the tab's own switch matters; any other defaults write is noise.
                guard let self, NotchIdleTab.isEnabled != self.enabledLastSeen else { return }
                self.enabledLastSeen = NotchIdleTab.isEnabled
                self.refresh()
            }
            .store(in: &cancellables)
        // A panel must not outlive a sleep/wake cycle or a display change: it can stop rendering
        // while still reporting itself visible, so it is rebuilt rather than repositioned.
        LifecycleObserver.shared.publisher(for: [.screenConfigurationChanged, .systemDidWake])
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.destroyPanel()
                self?.refresh()
            }
            .store(in: &cancellables)
        refresh()
    }

    private func refresh() {
        guard let uiManager else { return }
        let screen = self.screen ?? Self.notchedScreen()
        let hasNotch = (screen?.safeAreaInsets.top ?? 0) > 0
        let show = NotchIdleTab.shouldShow(
            enabled: NotchIdleTab.isEnabled, style: uiManager.recorderPanelStyle, hasNotch: hasNotch,
            recorderPanelVisible: uiManager.isRecorderPanelVisible)
        guard show, let screen else {
            // Hidden while hovered, which is what a click on the tab does: the panel never sees
            // the pointer leave, so it is rebuilt next time instead of coming back expanded.
            if hovered { destroyPanel() } else { panel?.orderOut(nil) }
            return
        }
        if panel == nil { buildPanel(on: screen) }
        guard let panel else { return }
        if !hovered { panel.setFrame(frame(hovered: false, on: screen), display: true) }
        panel.orderFrontRegardless()
    }

    /// The tab hangs from a physical notch, so it belongs on the screen that has one, not on
    /// whichever screen holds the key window. Without a notched screen it falls back to the main one.
    private static func notchedScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? RecorderScreenResolver.resolve()
    }

    private func buildPanel(on screen: NSScreen) {
        self.screen = screen
        notchHeight = screen.safeAreaInsets.top
        notchWidth = {
            if let left = screen.auxiliaryTopLeftArea?.width, let right = screen.auxiliaryTopRightArea?.width {
                return screen.frame.width - left - right
            }
            return 180
        }()
        let newPanel = NotchIdleTabPanel(contentRect: frame(hovered: false, on: screen))
        let view = NotchIdleTabView(
            notchWidth: notchWidth, notchHeight: notchHeight,
            onHoverChange: { [weak self] inside in self?.hoverChanged(inside) },
            onTap: { [weak self] in
                guard let uiManager = self?.uiManager else { return }
                Task { @MainActor in await uiManager.toggleRecorderPanel() }
            })
        newPanel.contentView = NotchRecorderHostingController(rootView: view).view
        panel = newPanel
        logger.notice(
            "Idle notch tab built notch=\(self.notchWidth, privacy: .public)x\(self.notchHeight, privacy: .public)")
    }

    private func frame(hovered: Bool, on screen: NSScreen) -> NSRect {
        NotchIdleTab.frame(
            for: NotchIdleTab.geometry(hovered: hovered, notchWidth: notchWidth), notchHeight: notchHeight,
            screenFrame: screen.frame)
    }

    /// The window grows before the shape animates out, and shrinks only after it has animated back.
    private func hoverChanged(_ inside: Bool) {
        ActivityTrail.mark("idle tab hover \(inside)")
        shrinkTask?.cancel()
        hovered = inside
        guard let panel, let screen else { return }
        if inside {
            panel.hasShadow = true
            panel.setFrame(frame(hovered: true, on: screen), display: true)
        } else {
            shrinkTask = Task { @MainActor [weak self, weak panel] in
                try? await Task.sleep(for: .seconds(NotchIdleTab.shrinkDelay))
                guard !Task.isCancelled, let self, let panel, let screen = self.screen else { return }
                panel.setFrame(self.frame(hovered: false, on: screen), display: true)
                panel.hasShadow = false
            }
        }
    }

    private func destroyPanel() {
        shrinkTask?.cancel()
        hovered = false
        panel?.orderOut(nil)
        panel = nil
        screen = nil
    }
}
