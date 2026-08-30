import AppKit
import SwiftData
import SwiftUI
import os

/// A thin panel docked to the left edge of the screen. Hovering the mouse at the very edge
/// slides it in, like VoiceOS's "click the left edge to see history" panel; moving away hides it.
final class EdgeHistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    static let panelWidth: CGFloat = 340
    /// How close to the edge (in screen points) the mouse must be to trigger the reveal.
    static let hoverTriggerZone: CGFloat = 6

    init(screen: NSScreen) {
        let frame = NSRect(
            x: screen.frame.minX,
            y: screen.frame.minY,
            width: Self.panelWidth,
            height: screen.frame.height
        )
        super.init(
            contentRect: frame,
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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
        styleMask.remove(.titled)
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovable = false
    }
}

@MainActor
final class EdgeHistoryWindowManager {
    static let shared = EdgeHistoryWindowManager()

    private var panel: EdgeHistoryPanel?
    private var hoverMonitor: Any?
    private var outsideDismissMonitor: Any?
    private var isExpanded = false
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
            guard let self else { return }
            Task { @MainActor in
                self.handleMouseMoved()
            }
        }
    }

    private func handleMouseMoved() {
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) else { return }

        if isExpanded {
            guard let panel else { return }
            let hoverZone = panel.frame.insetBy(dx: -40, dy: 0)
            if !hoverZone.contains(mouseLocation) {
                collapse()
            }
            return
        }

        guard mouseLocation.x <= screen.frame.minX + EdgeHistoryPanel.hoverTriggerZone else { return }
        expand(on: screen)
    }

    private func expand(on screen: NSScreen) {
        guard let modelContainer, let engine, !isExpanded else { return }

        if panel == nil {
            let newPanel = EdgeHistoryPanel(screen: screen)
            let content = EdgeHistorySidebarView(
                onSelectTranscription: { [weak self] in
                    self?.openHistoryWindow()
                }
            )
            .modelContainer(modelContainer)
            .environmentObject(engine)
            let hostingController = NSHostingController(rootView: content)
            newPanel.contentView = hostingController.view
            panel = newPanel
        }

        guard let panel else { return }
        isExpanded = true
        panel.orderFrontRegardless()
        installOutsideDismissMonitor()
    }

    private func collapse() {
        guard isExpanded else { return }
        isExpanded = false
        panel?.orderOut(nil)
        removeOutsideDismissMonitor()
    }

    private func installOutsideDismissMonitor() {
        removeOutsideDismissMonitor()
        outsideDismissMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            Task { @MainActor in
                self?.collapse()
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
        collapse()
        HistoryWindowController.shared.showHistoryWindow(modelContainer: modelContainer, engine: engine)
    }
}
