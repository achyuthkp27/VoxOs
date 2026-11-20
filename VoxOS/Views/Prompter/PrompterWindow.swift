import AppKit
import SwiftUI

/// The prompter's window: a black band that grows down out of the notch (or, on a display without
/// one, out of the top edge where a notch would be), with the script centred under it, as close
/// to the camera as the screen allows, so reading looks like looking at the viewer. It never takes
/// the keyboard or activates VoxOS; clicks and scrolling on it move the place, and its bottom-right
/// corner drags it wider or taller.
@MainActor
final class PrompterWindow {
    /// The scoop where the band meets the top edge, and its rounded bottom corners.
    nonisolated static let shoulder: CGFloat = 10
    nonisolated static let bottomRadius: CGFloat = 22
    nonisolated static let widthRange: ClosedRange<CGFloat> = 300...1000
    nonisolated static let linesRange: ClosedRange<Int> = 2...8

    private var panel: PrompterPanel?
    private let metrics = PrompterMetrics()
    private var observers: [NSObjectProtocol] = []
    private var scrollMonitor: Any?
    private var scrolled: CGFloat = 0

    static var fontSize: CGFloat { CGFloat(UserDefaults.standard.double(forKey: DefaultsKeys.prompterFontSize)) }
    static var lines: Int { UserDefaults.standard.integer(forKey: DefaultsKeys.prompterLines) }
    static var width: CGFloat { CGFloat(UserDefaults.standard.double(forKey: DefaultsKeys.prompterWidth)) }
    static var hiddenFromCapture: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.prompterHiddenFromCapture) }

    /// Height of `lines` lines of `fontSize` text.
    nonisolated static func textHeight(fontSize: CGFloat, lines: Int) -> CGFloat {
        CGFloat(max(lines, 1)) * (fontSize * PrompterView.lineHeight + fontSize * PrompterView.lineGap)
    }

    /// The band's height: the notch row, then `lines` lines of text with room above and below.
    nonisolated static func height(fontSize: CGFloat, lines: Int, notchHeight: CGFloat) -> CGFloat {
        notchHeight + textHeight(fontSize: fontSize, lines: lines) + PrompterView.padding * 2
    }

    /// The whole number of lines closest to a band dragged to `height`, within `linesRange`.
    nonisolated static func lines(forHeight height: CGFloat, fontSize: CGFloat, notchHeight: CGFloat) -> Int {
        let perLine = textHeight(fontSize: fontSize, lines: 1)
        guard perLine > 0 else { return linesRange.lowerBound }
        let fitted = Int(((height - notchHeight - PrompterView.padding * 2) / perLine).rounded())
        return min(max(fitted, linesRange.lowerBound), linesRange.upperBound)
    }

    /// Where the band goes on `screen`: centred on the notch, its top on the screen's top edge.
    nonisolated static func frame(on screenFrame: CGRect, size: CGSize) -> CGRect {
        CGRect(
            x: (screenFrame.midX - size.width / 2).rounded(), y: screenFrame.maxY - size.height,
            width: size.width, height: size.height)
    }

    /// The band is never narrower than the notch and its shoulders, nor wider than the screen.
    nonisolated static func width(_ wanted: CGFloat, notchWidth: CGFloat, screenWidth: CGFloat) -> CGFloat {
        let narrowest = max(widthRange.lowerBound, notchWidth + (shoulder + 16) * 2)
        return max(min(wanted, screenWidth - 40), min(narrowest, screenWidth - 40))
    }

    static func notchHeight(on screen: NSScreen) -> CGFloat {
        screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : NotchDesign.fallbackNotchHeight
    }

    /// The physical notch's width; 0 on a display without one.
    static func notchWidth(on screen: NSScreen) -> CGFloat {
        guard screen.safeAreaInsets.top > 0, let left = screen.auxiliaryTopLeftArea?.width,
            let right = screen.auxiliaryTopRightArea?.width
        else { return 0 }
        return screen.frame.width - left - right
    }

    /// A drag on the corner ended: the size is kept as a width and a number of lines, and the band
    /// settles on the nearest whole line.
    static func keep(size: CGSize, on screen: NSScreen?) {
        let notch = screen.map(notchHeight(on:)) ?? NotchDesign.fallbackNotchHeight
        let defaults = UserDefaults.standard
        defaults.set(Double(size.width.rounded()), forKey: DefaultsKeys.prompterWidth)
        defaults.set(
            lines(forHeight: size.height, fontSize: fontSize, notchHeight: notch), forKey: DefaultsKeys.prompterLines)
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        relayout()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            panel.animator().alphaValue = 1
        }
        watch()
    }

    func hide() {
        unwatch()
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.15
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }

    func relayout() {
        guard let panel, !metrics.isResizing else { return }
        let screen = NotchScreens.target() ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let notchHeight = Self.notchHeight(on: screen)
        if metrics.notchHeight != notchHeight { metrics.notchHeight = notchHeight }
        let size = CGSize(
            width: Self.width(Self.width, notchWidth: Self.notchWidth(on: screen), screenWidth: screen.frame.width),
            height: Self.height(fontSize: Self.fontSize, lines: Self.lines, notchHeight: notchHeight))
        panel.setFrame(Self.frame(on: screen.frame, size: size), display: true)
        let sharing: NSWindow.SharingType = Self.hiddenFromCapture ? .none : .readOnly
        if panel.sharingType != sharing { panel.sharingType = sharing }
    }

    private func makePanel() -> PrompterPanel {
        let panel = PrompterPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 160),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // A band joined to the top edge throws no shadow, like the notch it grows out of.
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        let host = NSHostingView(rootView: PrompterView(prompter: Prompter.shared, metrics: metrics))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    private func watch() {
        guard observers.isEmpty else { return }
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.relayout() }
            })
        observers.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.relayout() }
            })
        // Scrolling over the band moves the place a few words at a time.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, let panel = self.panel, event.window === panel else { return event }
            self.scrolled += event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : 12)
            let step: CGFloat = 24
            while abs(self.scrolled) >= step {
                let back = self.scrolled > 0
                self.scrolled -= back ? step : -step
                Prompter.shared.nudge(by: back ? -3 : 3)
            }
            return nil
        }
    }

    private func unwatch() {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        scrolled = 0
    }
}

/// What the view needs from the window: the notch row's height, and whether the corner is being
/// dragged (the window then leaves its frame alone).
@MainActor
final class PrompterMetrics: ObservableObject {
    @Published var notchHeight: CGFloat = NotchDesign.fallbackNotchHeight
    var isResizing = false
}

final class PrompterPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The band: an empty notch row with the listening dot beside the notch, then the script with the
/// current word lit, and, under the pointer, the controls.
struct PrompterView: View {
    nonisolated static let lineHeight: CGFloat = 1.22
    nonisolated static let lineGap: CGFloat = 0.3
    nonisolated static let padding: CGFloat = 14

    @ObservedObject var prompter: Prompter
    @ObservedObject var metrics: PrompterMetrics
    @AppStorage(DefaultsKeys.prompterFontSize) private var fontSize = 20.0
    @AppStorage(DefaultsKeys.prompterOpacity) private var opacity = 1.0
    @AppStorage(DefaultsKeys.prompterTextColor) private var textColorHex = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var currentWord: Int { prompter.script.wordIndex(atSpoken: prompter.cursor) }
    private var textColor: Color { PrompterTextColor.color(hex: textColorHex) }
    private var shape: NotchShape {
        NotchShape(topCornerRadius: PrompterWindow.shoulder, bottomCornerRadius: PrompterWindow.bottomRadius)
    }
    /// Content sits inside the drawn body, which is narrower than the frame by the shoulders.
    private var sideInset: CGFloat { PrompterWindow.shoulder + Self.padding }

    var body: some View {
        ZStack(alignment: .top) {
            shape.fill(Color.black.opacity(opacity))
            // Solid black through the notch row, so the band reads as the notch itself, fading
            // into the Background setting's opacity just below it.
            LinearGradient(
                stops: [.init(color: .black, location: 0.7), .init(color: .black.opacity(0), location: 1)],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: metrics.notchHeight + 10)
            VStack(spacing: 0) {
                notchRow.frame(height: metrics.notchHeight)
                scriptView
                    .padding(.horizontal, sideInset)
                    .padding(.vertical, Self.padding)
                    .mask(fadeMask)
            }
            if let problem = prompter.problem {
                Text(verbatim: problem.message)
                    .font(.app(.caption))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.9)))
                    .padding(.horizontal, sideInset)
                    .padding(.top, metrics.notchHeight + 6)
            }
            if hovering {
                controls
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity)
            }
            PrompterResizeGrip(metrics: metrics)
                .frame(width: 22, height: 22)
                .padding(.trailing, PrompterWindow.shoulder)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
        .clipShape(shape)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
            prompter.setHoverPaused(inside)
        }
        .environment(\.colorScheme, .dark)
    }

    private var notchRow: some View {
        HStack {
            meter
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PrompterWindow.shoulder + 14)
    }

    private var scriptView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .center, spacing: fontSize * Self.lineGap * 2) {
                    ForEach(0..<prompter.script.paragraphCount, id: \.self) { paragraph in
                        FlowLayout(spacing: fontSize * Self.lineGap, centered: true) {
                            ForEach(words(in: paragraph), id: \.self) { index in
                                word(index)
                            }
                        }
                    }
                    if !prompter.hasScript {
                        Text("Add a script in Settings → Voice Prompter.")
                            .font(.system(size: fontSize * 0.7, weight: .medium, design: .rounded))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                // Room after the last line, so it can scroll up to the reading line.
                .padding(.bottom, fontSize * 4)
            }
            .scrollDisabled(true)
            .onChange(of: currentWord) { _, word in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
                    proxy.scrollTo(word, anchor: UnitPoint(x: 0.5, y: 0.18))
                }
            }
            .onAppear { proxy.scrollTo(currentWord, anchor: UnitPoint(x: 0.5, y: 0.18)) }
        }
    }

    private func words(in paragraph: Int) -> [Int] {
        prompter.script.words.indices.filter { prompter.script.words[$0].paragraph == paragraph }
    }

    private func word(_ index: Int) -> some View {
        let word = prompter.script.words[index]
        let read = index < currentWord
        let current = index == currentWord
        return Text(verbatim: word.text)
            .font(
                .system(
                    size: word.isNote ? fontSize * 0.8 : fontSize, weight: current ? .bold : .semibold,
                    design: .rounded)
            )
            .italic(word.isNote)
            .foregroundStyle(
                word.isNote
                    ? AnyShapeStyle(Color.orange.opacity(read ? 0.35 : 0.8))
                    : current
                        ? AnyShapeStyle(AppTheme.Accent.primary)
                        : AnyShapeStyle(textColor.opacity(read ? 0.32 : 0.95))
            )
            .id(index)
            .contentShape(Rectangle())
            .onTapGesture { prompter.jump(toWord: index) }
    }

    /// The top and bottom lines fade, so text scrolls in and out rather than being cut.
    private var fadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.82), .init(color: .clear, location: 1),
            ], startPoint: .top, endPoint: .bottom)
    }

    /// Lit while following; at a steady pace with the microphone, lit only while it hears speaking.
    private var meter: some View {
        let hearing = prompter.follow == .words || prompter.isSpeaking || !prompter.usesMicrophone
        let lit = prompter.isListening && !prompter.isHoverPaused && hearing
        return Circle()
            .fill(lit ? AppTheme.Accent.primary : Color.white.opacity(0.25))
            .frame(width: 7, height: 7)
            .scaleEffect(prompter.isListening ? 1 + CGFloat(prompter.level) * 0.8 : 1)
            .animation(.easeOut(duration: 0.1), value: prompter.level)
            .help(meterHelp)
    }

    private var meterHelp: String {
        if !prompter.isListening { return String(localized: "Not listening") }
        if prompter.isHoverPaused { return String(localized: "Waiting while the pointer is over it") }
        return prompter.follow == .words ? String(localized: "Listening") : String(localized: "Moving at a steady pace")
    }

    private var controls: some View {
        HStack(spacing: 4) {
            if prompter.follow == .pace {
                control(
                    prompter.isListening ? "pause.fill" : "play.fill",
                    help: prompter.isListening ? String(localized: "Pause") : String(localized: "Play")
                ) { prompter.toggleListening() }
            } else {
                control(
                    prompter.isListening ? "mic.fill" : "mic.slash.fill",
                    help: prompter.isListening ? String(localized: "Pause Listening") : String(localized: "Listen")
                ) { prompter.toggleListening() }
            }
            control("arrow.counterclockwise", help: String(localized: "Start Over")) { prompter.restart() }
            control("textformat.size.smaller", help: String(localized: "Smaller Text")) {
                fontSize = max(14, fontSize - 2)
            }
            control("textformat.size.larger", help: String(localized: "Larger Text")) {
                fontSize = min(48, fontSize + 2)
            }
            control("xmark", help: String(localized: "Close Prompter")) { prompter.stop() }
        }
        .padding(4)
        .background(Capsule().fill(Color.white.opacity(0.12)))
        .background(Capsule().fill(Color.black.opacity(0.7)))
    }

    private func control(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.85))
        .help(help)
        .accessibilityLabel(Text(verbatim: help))
    }
}

/// The band's bottom-right corner: dragging it makes the band wider (on both sides, so it stays
/// centred on the notch) or taller. The top stays on the screen's edge.
struct PrompterResizeGrip: NSViewRepresentable {
    let metrics: PrompterMetrics

    func makeNSView(context: Context) -> PrompterResizeGripView {
        let view = PrompterResizeGripView()
        view.metrics = metrics
        return view
    }

    func updateNSView(_ view: PrompterResizeGripView, context: Context) { view.metrics = metrics }
}

final class PrompterResizeGripView: NSView {
    weak var metrics: PrompterMetrics?
    private var startFrame = CGRect.zero
    private var startMouse = CGPoint.zero
    private var tracking: NSTrackingArea?

    private static var cursor: NSCursor {
        if #available(macOS 15.0, *) { return NSCursor.frameResize(position: .bottomRight, directions: .all) }
        return NSCursor.crosshair
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // The panel is never key, so the cursor is set on entering rather than by cursor rects.
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { Self.cursor.set() }

    override func mouseExited(with event: NSEvent) {
        guard NSEvent.pressedMouseButtons == 0 else { return }
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        metrics?.isResizing = true
        startFrame = window.frame
        startMouse = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let screen = window.screen else { return }
        Self.cursor.set()
        let mouse = NSEvent.mouseLocation
        let fontSize = PrompterWindow.fontSize
        let notchHeight = PrompterWindow.notchHeight(on: screen)
        let width = PrompterWindow.width(
            min(
                max(startFrame.width + (mouse.x - startMouse.x) * 2, PrompterWindow.widthRange.lowerBound),
                PrompterWindow.widthRange.upperBound),
            notchWidth: PrompterWindow.notchWidth(on: screen), screenWidth: screen.frame.width)
        let shortest = PrompterWindow.height(
            fontSize: fontSize, lines: PrompterWindow.linesRange.lowerBound, notchHeight: notchHeight)
        let tallest = PrompterWindow.height(
            fontSize: fontSize, lines: PrompterWindow.linesRange.upperBound, notchHeight: notchHeight)
        let height = min(max(startFrame.height - (mouse.y - startMouse.y), shortest), tallest)
        window.setFrame(
            CGRect(
                x: (startFrame.midX - width / 2).rounded(), y: startFrame.maxY - height, width: width, height: height),
            display: true)
    }

    override func mouseUp(with event: NSEvent) {
        metrics?.isResizing = false
        guard let window else { return }
        PrompterWindow.keep(size: window.frame.size, on: window.screen)
        // Settle on the nearest whole line even when nothing stored changed.
        Prompter.shared.settingsChanged()
        if !bounds.contains(convert(event.locationInWindow, from: nil)) { NSCursor.arrow.set() }
    }
}
