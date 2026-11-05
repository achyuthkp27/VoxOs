import AppKit
import SwiftUI

/// The letters shown while the app switcher's key is held on its own: each letter that reaches an
/// app, and the app it brings forward. It never takes a click or a key; letting go of the key, or
/// using it, takes it away.
@MainActor
final class LetterSheet: ObservableObject {
    static let shared = LetterSheet()

    struct Item: Identifiable {
        let letter: String
        let name: String
        let icon: NSImage?
        /// Given this letter in Settings, rather than reached by its name.
        let assigned: Bool

        var id: String { letter }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var trigger: AppSwitcher.Trigger = .rightCommand

    private var panel: NSPanel?

    private init() {}

    func show(_ reaches: [AppSwitcher.Reach], trigger: AppSwitcher.Trigger) {
        guard !reaches.isEmpty else { return }
        items = reaches.map { reach in
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: reach.id)
            return Item(
                letter: reach.letter, name: AppSwitcher.name(of: reach.id),
                icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) }, assigned: reach.assigned)
        }
        self.trigger = trigger
        if panel == nil {
            let panel = NSPanel(
                contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .popUpMenu
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: LetterSheetView(sheet: self))
            self.panel = panel
        }
        guard let panel, let view = panel.contentView, let visible = NSScreen.underPointer?.visibleFrame else { return }
        let size = view.fittingSize
        panel.setFrame(
            CGRect(origin: CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2), size: size),
            display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        guard let panel else { return }
        panel.orderOut(nil)
        self.panel = nil
    }
}
