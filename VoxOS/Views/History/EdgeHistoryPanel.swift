import AppKit
import SwiftData
import SwiftUI
import os

/// A panel docked to the left edge of the screen. It has two visual states:
/// a slim "notch" handle that appears when the mouse reaches the left edge, and —
/// once that notch is clicked — a compact, height-limited history card.
final class EdgeHistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Width of the expanded history card.
    static let panelWidth: CGFloat = 400
    /// Corner radius of the expanded card.
    static let cornerRadius: CGFloat = 26
    /// Maximum height of the expanded history card; it never fills the whole screen.
    static let maxPanelHeight: CGFloat = 600
    /// Fraction of the screen height the expanded card is allowed to take.
    static let panelHeightFraction: CGFloat = 0.72
    /// Width of the collapsed notch handle (includes a little slack for the click target).
    static let notchWidth: CGFloat = 16
    /// Height of the collapsed notch handle.
    static let notchHeight: CGFloat = 96
    /// How close to the edge (in screen points) the mouse must be to reveal the notch.
    static let hoverTriggerZone: CGFloat = 4
    /// Inset of the expanded card from the screen edge.
    static let edgeInset: CGFloat = 6

    init(screen: NSScreen) {
        super.init(
            contentRect: Self.notchFrame(on: screen),
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .hudWindow],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        canHide = false
        level = .statusBar + 2
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
        styleMask.remove(.titled)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovable = false
    }

    /// Frame of the slim handle, vertically centred on the left edge.
    static func notchFrame(on screen: NSScreen) -> NSRect {
        NSRect(
            x: screen.frame.minX,
            y: screen.frame.midY - notchHeight / 2,
            width: notchWidth,
            height: notchHeight
        )
    }

    /// Frame of the expanded card — a fixed, limited height centred on the left edge.
    static func expandedFrame(on screen: NSScreen) -> NSRect {
        let height = min(maxPanelHeight, screen.visibleFrame.height * panelHeightFraction)
        return NSRect(
            x: screen.frame.minX + edgeInset,
            y: screen.frame.midY - height / 2,
            width: panelWidth,
            height: height
        )
    }
}

@MainActor
final class EdgeHistoryWindowManager {
    static let shared = EdgeHistoryWindowManager()

    private enum State {
        case hidden
        case notch
        case expanded
    }

    private var panel: EdgeHistoryPanel?
    private var hoverMonitor: Any?
    private var localHoverMonitor: Any?
    private var outsideDismissMonitor: Any?
    private var state: State = .hidden
    private let presentation = EdgeHistoryPresentation()
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "EdgeHistoryWindowManager")

    private var modelContainer: ModelContainer?
    private var engine: VoxOSEngine?

    private init() {}

    func configure(modelContainer: ModelContainer, engine: VoxOSEngine) {
        self.modelContainer = modelContainer
        self.engine = engine
        installHoverMonitor()
    }

    private func installHoverMonitor() {
        guard hoverMonitor == nil else { return }
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in self?.handleMouseMoved() }
        }
        localHoverMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in self?.handleMouseMoved() }
            return event
        }
    }

    private func handleMouseMoved() {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
        else { return }

        switch state {
        case .expanded:
            // The card stays put while the pointer is over it (or just beside it); it is
            // dismissed by clicking elsewhere or by walking away — unless pinned.
            guard let panel, !presentation.isPinned else { return }
            let hoverZone = panel.frame.insetBy(dx: -60, dy: -40)
            if !NSMouseInRect(mouseLocation, hoverZone, false) {
                hide()
            }

        case .notch:
            guard let panel else { return }
            let hoverZone = panel.frame.insetBy(dx: -70, dy: -70)
            if !NSMouseInRect(mouseLocation, hoverZone, false) {
                hide()
            }

        case .hidden:
            guard mouseLocation.x <= screen.frame.minX + EdgeHistoryPanel.hoverTriggerZone else { return }
            // Only the middle band of the edge reveals the notch, so the menu bar and
            // Dock corners stay usable.
            let band = EdgeHistoryPanel.notchHeight * 2.2
            guard abs(mouseLocation.y - screen.frame.midY) <= band / 2 else { return }
            showNotch(on: screen)
        }
    }

    // MARK: - State transitions

    private func showNotch(on screen: NSScreen) {
        guard let modelContainer, let engine, state == .hidden else { return }
        let panel = ensurePanel(on: screen, modelContainer: modelContainer, engine: engine)

        state = .notch
        presentation.isExpanded = false
        panel.hasShadow = false
        panel.setFrame(EdgeHistoryPanel.notchFrame(on: screen), display: true)
        panel.orderFrontRegardless()
        removeOutsideDismissMonitor()
    }

    private func expand() {
        guard state == .notch, let panel, let screen = panel.screen ?? NSScreen.main else { return }

        state = .expanded
        panel.hasShadow = true
        let target = EdgeHistoryPanel.expandedFrame(on: screen)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
        }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            presentation.isExpanded = true
        }
        panel.makeKeyAndOrderFront(nil)
        installOutsideDismissMonitor()
    }

    private func hide() {
        guard state != .hidden else { return }
        state = .hidden
        presentation.isExpanded = false
        presentation.isPinned = false
        panel?.orderOut(nil)
        if let panel, let screen = panel.screen ?? NSScreen.main {
            panel.setFrame(EdgeHistoryPanel.notchFrame(on: screen), display: false)
        }
        removeOutsideDismissMonitor()
    }

    private func ensurePanel(
        on screen: NSScreen,
        modelContainer: ModelContainer,
        engine: VoxOSEngine
    ) -> EdgeHistoryPanel {
        if let panel { return panel }

        let newPanel = EdgeHistoryPanel(screen: screen)
        let content = EdgeHistoryContainerView(
            presentation: presentation,
            onNotchTap: { [weak self] in self?.expand() },
            onSelectTranscription: { [weak self] in self?.openHistoryWindow() },
            onDismiss: { [weak self] in self?.hide() }
        )
        .modelContainer(modelContainer)
        .environmentObject(engine)

        // A non-activating panel consumes the first click to become key, which would
        // otherwise swallow the tap that opens the card — so the hosting view opts into
        // receiving that first click directly.
        let hostingView = FirstMouseHostingView(rootView: AnyView(content))
        // The panel's frame is animated between the notch and card sizes. If the hosting
        // view also published size constraints it would re-invalidate layout on every
        // animation frame, and AppKit aborts with "more Update Constraints in Window
        // passes than there are views in the window". The window drives the size here.
        hostingView.sizingOptions = []

        // The hosting view is deliberately NOT the panel's contentView. As a contentView it
        // drives the window's size to match its SwiftUI content (NSHostingView
        // .updateAnimatedWindowSize), which fights the frame animation between the notch and
        // card sizes and loops until AppKit aborts the layout pass. Nested in a plain
        // container it just fills whatever size the window is given.
        let container = NSView(frame: newPanel.contentLayoutRect)
        container.autoresizesSubviews = true
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        newPanel.contentView = container
        panel = newPanel
        return newPanel
    }

    private func installOutsideDismissMonitor() {
        removeOutsideDismissMonitor()
        outsideDismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            Task { @MainActor in
                guard let self, !self.presentation.isPinned else { return }
                self.hide()
            }
        }
    }

    private func removeOutsideDismissMonitor() {
        if let outsideDismissMonitor {
            NSEvent.removeMonitor(outsideDismissMonitor)
        }
        outsideDismissMonitor = nil
    }

    private func openHistoryWindow() {
        guard let modelContainer, let engine else { return }
        hide()
        HistoryWindowController.shared.showHistoryWindow(modelContainer: modelContainer, engine: engine)
    }
}

/// Hosting view that responds to the click that also makes its panel key, so the notch
/// opens on a single click instead of requiring one click to focus and another to act.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @MainActor required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    @MainActor required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Shared state between the AppKit panel and its SwiftUI content.
@MainActor
final class EdgeHistoryPresentation: ObservableObject {
    @Published var isExpanded = false
    /// Pinned by the lock button: the card ignores mouse-away and outside clicks until unpinned.
    @Published var isPinned = false
}
