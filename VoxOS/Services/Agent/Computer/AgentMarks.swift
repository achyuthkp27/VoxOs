import AppKit
import Foundation

/// Set-of-marks for a voice agent. Numbered badges are drawn over every clickable region
/// on the *user's* screen so they can say "click 7" — the agent itself is text-only, so the
/// numbers exist for the person, not for a vision model. Candidates come from both the
/// Accessibility tree (labelled controls) and OCR (visible text), de-duplicated by position.
/// Ported and adapted from cursor-voice (MIT) MarkOverlay.
@MainActor
enum AgentMarks {

    struct Mark {
        let index: Int
        let label: String
        /// Global screen points, top-left origin.
        let frame: CGRect
    }

    private(set) static var current: [Mark] = []
    private static var overlay: MarkOverlayPanel?
    private static var hideTask: Task<Void, Never>?

    /// How long the badges stay on screen before clearing themselves.
    static let displaySeconds: TimeInterval = 30

    /// Build marks from the current screen and show them to the user.
    static func markScreen() async -> [String: Any] {
        guard let shot = await AgentScreen.capture() else {
            return ["error": "screen capture failed — Screen Recording permission may be missing"]
        }
        let elements = AgentAXTree.enumerateFrontmost()
        let ocr = await AgentScreen.recognizeText(in: shot)

        var raw: [(frame: CGRect, label: String)] = []
        for e in elements where e.frame.width >= 8 && e.frame.height >= 8 {
            raw.append((e.frame, e.title))
        }
        for m in ocr where m.frame.width >= 8 && m.frame.height >= 8 {
            raw.append((m.frame, m.text))
        }

        var kept: [(frame: CGRect, label: String)] = []
        for candidate in raw {
            let c = CGPoint(x: candidate.frame.midX, y: candidate.frame.midY)
            if let i = kept.firstIndex(where: { abs($0.frame.midX - c.x) < 12 && abs($0.frame.midY - c.y) < 12 }) {
                if kept[i].label.isEmpty, !candidate.label.isEmpty { kept[i] = candidate }
            } else {
                kept.append(candidate)
            }
            if kept.count >= 80 { break }
        }

        // Read in the order a person scans: top to bottom, then left to right.
        kept.sort { AgentScreen.readingOrderKey($0.frame, rowHeight: 14) < AgentScreen.readingOrderKey($1.frame, rowHeight: 14) }
        current = kept.enumerated().map { Mark(index: $0.offset + 1, label: $0.element.label, frame: $0.element.frame) }

        show(on: shot.displayBounds)

        return [
            "count": current.count,
            "marks": current.map { ["mark": $0.index, "label": String($0.label.prefix(40))] },
            "note": "Numbered badges are now visible on the user's screen for \(Int(displaySeconds))s. Pick the mark whose label matches the target and call click_mark, or ask the user which number they mean.",
        ]
    }

    static func mark(numbered n: Int) -> Mark? {
        current.first { $0.index == n }
    }

    static func clear() {
        hideTask?.cancel()
        hideTask = nil
        overlay?.orderOut(nil)
        overlay = nil
        current = []
    }

    // MARK: - Overlay

    private static func show(on displayBounds: CGRect) {
        overlay?.orderOut(nil)

        // CG display bounds are top-left origin; NSWindow frames are bottom-left, relative to
        // the primary screen. Flip using the primary screen's height.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? displayBounds.height
        let cocoaFrame = NSRect(
            x: displayBounds.minX,
            y: primaryHeight - displayBounds.maxY,
            width: displayBounds.width,
            height: displayBounds.height)

        let panel = MarkOverlayPanel(contentRect: cocoaFrame)
        panel.contentView = MarkOverlayView(marks: current, displayBounds: displayBounds)
        panel.orderFrontRegardless()
        overlay = panel

        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(displaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            clear()
        }
    }
}

/// Transparent, click-through, always-on-top panel that the badges are drawn into.
private final class MarkOverlayPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
    }
}

private final class MarkOverlayView: NSView {
    private let marks: [AgentMarks.Mark]
    private let displayBounds: CGRect

    init(marks: [AgentMarks.Mark], displayBounds: CGRect) {
        self.marks = marks
        self.displayBounds = displayBounds
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let stroke = NSColor(red: 0.98, green: 0.55, blue: 0.15, alpha: 0.95)
        let fill = NSColor(red: 0.98, green: 0.55, blue: 0.15, alpha: 1)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]

        for m in marks {
            // Global top-left points → local top-left points (view is flipped).
            let r = NSRect(
                x: m.frame.minX - displayBounds.minX, y: m.frame.minY - displayBounds.minY,
                width: m.frame.width, height: m.frame.height)
            let outline = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            outline.lineWidth = 1.5
            stroke.setStroke()
            outline.stroke()

            let badge = "\(m.index)"
            let size = badge.size(withAttributes: attrs)
            let pad: CGFloat = 4
            let badgeRect = NSRect(x: r.minX, y: r.minY - size.height - 2, width: size.width + pad * 2, height: size.height + 2)
            let clamped = badgeRect.minY < 0 ? badgeRect.offsetBy(dx: 0, dy: size.height + 4) : badgeRect
            fill.setFill()
            NSBezierPath(roundedRect: clamped, xRadius: 3, yRadius: 3).fill()
            badge.draw(at: NSPoint(x: clamped.minX + pad, y: clamped.minY + 1), withAttributes: attrs)
        }
    }
}
