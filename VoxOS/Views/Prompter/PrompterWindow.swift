import AppKit
import SwiftUI

/// The prompter's window: a dark card hanging just under the menu bar in the middle of the notch's
/// display, as close to the camera as the screen allows, so reading looks like looking at the
/// viewer. It never takes the keyboard or activates VoxOS; clicks and scrolling on it move the place.
@MainActor
final class PrompterWindow {
    private var panel: PrompterPanel?
    private var observers: [NSObjectProtocol] = []
    private var scrollMonitor: Any?
    private var scrolled: CGFloat = 0

    static var fontSize: CGFloat { CGFloat(UserDefaults.standard.double(forKey: DefaultsKeys.prompterFontSize)) }
    static var lines: Int { UserDefaults.standard.integer(forKey: DefaultsKeys.prompterLines) }
    static var width: CGFloat { CGFloat(UserDefaults.standard.double(forKey: DefaultsKeys.prompterWidth)) }
    static var hiddenFromCapture: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.prompterHiddenFromCapture) }

    /// The card's height for `lines` lines of `fontSize` text.
    nonisolated static func height(fontSize: CGFloat, lines: Int) -> CGFloat {
        CGFloat(max(lines, 1)) * (fontSize * PrompterView.lineHeight + fontSize * PrompterView.lineGap)
            + PrompterView.padding * 2
    }

    /// Where the card goes on `screen`: centred, its top just under the menu bar (or the notch).
    nonisolated static func frame(on screenFrame: CGRect, topInset: CGFloat, size: CGSize) -> CGRect {
        CGRect(
            x: (screenFrame.midX - size.width / 2).rounded(), y: screenFrame.maxY - topInset - 6 - size.height,
            width: size.width, height: size.height)
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
        guard let panel else { return }
        let screen = NotchScreens.target() ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let size = CGSize(
            width: min(Self.width, screen.frame.width - 40),
            height: Self.height(fontSize: Self.fontSize, lines: Self.lines))
        let topInset = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        panel.setFrame(Self.frame(on: screen.frame, topInset: topInset, size: size), display: true)
        let sharing: NSWindow.SharingType = Self.hiddenFromCapture ? .none : .readOnly
        if panel.sharingType != sharing { panel.sharingType = sharing }
    }

    private func makePanel() -> PrompterPanel {
        let panel = PrompterPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 160),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        let host = NSHostingView(rootView: PrompterView(prompter: Prompter.shared))
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
        // Scrolling over the card moves the place a few words at a time.
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

final class PrompterPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The card: the script with the current word lit, a level meter, and, under the pointer, the
/// controls.
struct PrompterView: View {
    static let lineHeight: CGFloat = 1.22
    static let lineGap: CGFloat = 0.3
    static let padding: CGFloat = 16

    @ObservedObject var prompter: Prompter
    @AppStorage(DefaultsKeys.prompterFontSize) private var fontSize = 24.0
    @AppStorage(DefaultsKeys.prompterOpacity) private var opacity = 0.92
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var currentWord: Int { prompter.script.wordIndex(atSpoken: prompter.cursor) }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.black.opacity(opacity))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            scriptView
                .padding(.horizontal, Self.padding + 8)
                .padding(.vertical, Self.padding)
                .mask(fadeMask)
            if let problem = prompter.problem {
                Text(verbatim: problem.message)
                    .font(.app(.caption))
                    .foregroundStyle(.orange)
                    .padding(8)
                    .background(Capsule().fill(Color.black.opacity(0.85)))
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            meter
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if hovering { controls.padding(10).transition(.opacity) }
        }
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
        }
        .environment(\.colorScheme, .dark)
    }

    private var scriptView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: fontSize * Self.lineGap * 2) {
                    ForEach(0..<prompter.script.paragraphCount, id: \.self) { paragraph in
                        FlowLayout(spacing: fontSize * Self.lineGap) {
                            ForEach(words(in: paragraph), id: \.self) { index in
                                word(index)
                            }
                        }
                    }
                    if !prompter.hasScript {
                        Text("Add a script in Settings → Voice Prompter.")
                            .font(.system(size: fontSize * 0.7, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Room after the last line, so it can scroll up to the reading line.
                .padding(.bottom, fontSize * 4)
            }
            .scrollDisabled(true)
            .onChange(of: currentWord) { _, word in
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.35)) {
                    proxy.scrollTo(word, anchor: UnitPoint(x: 0, y: 0.18))
                }
            }
            .onAppear { proxy.scrollTo(currentWord, anchor: UnitPoint(x: 0, y: 0.18)) }
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
            .font(.system(size: word.isNote ? fontSize * 0.8 : fontSize, weight: current ? .bold : .semibold))
            .italic(word.isNote)
            .foregroundStyle(
                word.isNote
                    ? AnyShapeStyle(Color.orange.opacity(read ? 0.35 : 0.8))
                    : current
                        ? AnyShapeStyle(AppTheme.Accent.primary)
                        : AnyShapeStyle(Color.white.opacity(read ? 0.32 : 0.95))
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

    private var meter: some View {
        Circle()
            .fill(prompter.isListening ? AppTheme.Accent.primary : Color.white.opacity(0.25))
            .frame(width: 7, height: 7)
            .scaleEffect(prompter.isListening ? 1 + CGFloat(prompter.level) * 0.8 : 1)
            .animation(.easeOut(duration: 0.1), value: prompter.level)
            .help(prompter.isListening ? String(localized: "Listening") : String(localized: "Not listening"))
    }

    private var controls: some View {
        HStack(spacing: 4) {
            control(
                prompter.isListening ? "mic.fill" : "mic.slash.fill",
                help: prompter.isListening ? String(localized: "Pause Listening") : String(localized: "Listen")
            ) { prompter.toggleListening() }
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
