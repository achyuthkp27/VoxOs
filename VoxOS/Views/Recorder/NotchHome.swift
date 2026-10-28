import AppKit
import Combine
import MediaRemoteAdapter
import QuartzCore
import SwiftUI
import os

/// The notch between dictations. Collapsed it says one thing at a time; hovered (or with files
/// dragged onto it) it opens into a small card with four pages: Music, Timer, Today and Shelf.
///
/// Collapsed, in order: a passing notice (a device connected, a timer finished), a running timer,
/// the playing track; otherwise a notch-sized black target that disappears into the hardware
/// notch and is only there to be hovered or dropped on.
///
/// Its own persistent panel, one level under Claude Code's: a Claude Code card (a request or a
/// question) or the recorder hides it, while its band takes the place of Claude Code's "working"
/// band, which would otherwise cover it for as long as a session runs.
enum NotchHome {
    static let artSize: CGFloat = 20
    /// Cover, inset and the band's shoulder: the same rule as Claude Code's glyph wing.
    static var wing: CGFloat { wing(holding: artSize) }
    /// Wide enough for "24:13" beside a small ring.
    static var timerWing: CGFloat { wing(holding: 40) }
    /// Wide enough for an icon and a short device name, or "Disconnected".
    static var noticeWing: CGFloat { wing(holding: 92) }

    static func wing(holding content: CGFloat) -> CGFloat {
        NotchDesign.listening.shoulder + NotchDesign.contentInset + content + NotchDesign.contentInset
    }

    /// The open card: the same height on every page, so switching pages never moves the notch.
    enum Card {
        static let height: CGFloat = 132
        static let top: CGFloat = 8
        static let progressHeight: CGFloat = 14
        static let controlsHeight: CGFloat = 30
        static var bottom: CGFloat { AgentComposer.panelBottomInset }
        /// Where the cover's fade into the card begins, as a fraction of its width.
        static let posterFadeStart: CGFloat = 0.62
    }

    struct Notice: Equatable {
        let symbol: String
        let title: String
        let detail: String?
    }

    enum Content: Equatable {
        case hidden
        /// Notch-sized and drawn black, so it disappears into the hardware notch: only there to
        /// be hovered or dropped on.
        case bare
        case playing
        case timer
        case notice(Notice)
        case expanded

        /// Shows something beyond the hardware notch.
        var isVisible: Bool { self != .hidden && self != .bare }
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.notchHomeEnabled) }
    static var musicEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.notchMusicEnabled) }
    static var barsEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.notchMusicBarsEnabled) }

    static func content(
        enabled: Bool, hasNotch: Bool, blocked: Bool, hovered: Bool, dropping: Bool, notice: Notice?,
        timerRunning: Bool, musicPlaying: Bool
    ) -> Content {
        guard enabled, hasNotch, !blocked else { return .hidden }
        if hovered || dropping { return .expanded }
        if let notice { return .notice(notice) }
        if timerRunning { return .timer }
        if musicPlaying { return .playing }
        return .bare
    }

    static func size(for content: Content, notchWidth: CGFloat, notchHeight: CGFloat) -> CGSize {
        switch content {
        case .hidden, .bare:
            return CGSize(width: notchWidth, height: notchHeight)
        case .playing:
            return CGSize(width: notchWidth + wing * 2, height: notchHeight)
        case .timer:
            return CGSize(width: notchWidth + timerWing * 2, height: notchHeight)
        case .notice:
            return CGSize(width: notchWidth + noticeWing * 2, height: notchHeight)
        case .expanded:
            return CGSize(
                width: max(NotchDesign.expandedWidth, notchWidth + wing * 2), height: notchHeight + Card.height)
        }
    }

    static func radii(for content: Content) -> NotchDesign.Radii {
        switch content {
        case .hidden, .bare: return NotchDesign.resting
        case .playing, .timer, .notice: return NotchDesign.listening
        case .expanded: return NotchDesign.expanded
        }
    }

    static func frame(for size: CGSize, screenFrame: CGRect) -> CGRect {
        ClaudeCodeNotch.frame(for: size, screenFrame: screenFrame)
    }

    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The parts of a MediaRemote payload the notch shows, with the cover decoded once per track.
struct NotchTrack: Equatable {
    let id: String
    let title: String
    let artist: String
    let isPlaying: Bool
    let duration: Double?
    /// Position at `stamp`; it advances by `rate` while playing.
    let elapsed: Double?
    let stamp: Date
    let rate: Double
    let artwork: NSImage?
    let tint: Color
    let bundleID: String?

    func position(at now: Date) -> Double? {
        guard let elapsed else { return nil }
        let advanced = isPlaying ? elapsed + now.timeIntervalSince(stamp) * rate : elapsed
        return duration.map { min(advanced, $0) } ?? advanced
    }

    static func == (lhs: NotchTrack, rhs: NotchTrack) -> Bool {
        lhs.id == rhs.id && lhs.isPlaying == rhs.isPlaying && lhs.elapsed == rhs.elapsed && lhs.stamp == rhs.stamp
            && lhs.artwork === rhs.artwork && lhs.bundleID == rhs.bundleID
    }
}

// MARK: - View

@MainActor
final class NotchHomeModel: ObservableObject {
    @Published var content: NotchHome.Content = .hidden
    @Published var track: NotchTrack?
    /// Shuffle and repeat as the player reports them; nil when it cannot say.
    @Published var modes: NotchPlaybackModes.State?
    @Published var page: NotchHomePage = .today
    /// Files are being dragged over the notch.
    @Published var dropping = false
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    init(notchWidth: CGFloat, notchHeight: CGFloat) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
    }
}

struct NotchHomeView: View {
    @ObservedObject var model: NotchHomeModel
    let onHover: (Bool) -> Void
    let onShuffle: () -> Void
    let onRepeat: () -> Void
    let onDropTargeted: (Bool) -> Void
    @AppStorage(DefaultsKeys.notchMusicBarsEnabled) private var barsEnabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var content: NotchHome.Content { model.content }
    private var size: CGSize {
        NotchHome.size(for: content, notchWidth: model.notchWidth, notchHeight: model.notchHeight)
    }
    private var shape: NotchShape { NotchShape(NotchHome.radii(for: content)) }
    private var inset: CGFloat { NotchHome.radii(for: content).shoulder + NotchDesign.contentInset }

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            if content == .expanded, model.page == .music, let track = model.track {
                // Up through the notch row as well: the top-left wing is otherwise an empty
                // black strip.
                NotchHomePoster(image: track.artwork, tint: track.tint)
                    .frame(width: size.width / 2, height: size.height)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .white, location: 0),
                                .init(color: .white, location: NotchHome.Card.posterFadeStart),
                                .init(color: .clear, location: 1),
                            ], startPoint: .leading, endPoint: .trailing)
                    )
                    .transition(.opacity)
            }
            VStack(spacing: 0) {
                notchRow
                if content == .expanded {
                    page
                        .frame(height: NotchHome.Card.height, alignment: .top)
                        .transition(.opacity)
                }
            }
            rim
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .contentShape(shape)
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onHover(perform: onHover)
        .dropDestination(for: URL.self) { urls, _ in
            NotchShelf.shared.add(urls)
            return !urls.isEmpty
        } isTargeted: { targeted in
            onDropTargeted(targeted)
        }
        .animation(
            reduceMotion ? nil : (content == .expanded ? NotchDesign.openAnimation : NotchDesign.closeAnimation),
            value: content)
    }

    @ViewBuilder
    private var page: some View {
        switch model.page {
        case .music:
            if let track = model.track {
                NotchHomePlayer(
                    track: track, modes: model.modes, barsEnabled: barsEnabled, onShuffle: onShuffle,
                    onRepeat: onRepeat
                )
                .frame(width: size.width / 2, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        case .timer:
            NotchTimerPage(timers: .shared)
        case .today:
            NotchTodayPage(today: .shared)
        case .shelf:
            NotchShelfPage(shelf: .shared, dropping: model.dropping)
        }
    }

    /// One thing in each wing. Open, the left wing names the page (behind the cover on Music)
    /// and the right one switches pages.
    private var notchRow: some View {
        HStack(spacing: 0) {
            leftWing
            Spacer(minLength: 0)
            rightWing
        }
        .padding(.horizontal, inset)
        .frame(width: size.width, height: model.notchHeight)
    }

    @ViewBuilder
    private var leftWing: some View {
        switch content {
        case .playing:
            if let track = model.track { NotchHomeArtwork(image: track.artwork, size: NotchHome.artSize, radius: 5) }
        case .timer:
            if let running = NotchTimers.shared.running {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    NotchTimerRing(progress: running.progress(at: context.date), kind: running.kind)
                        .frame(width: 14, height: 14)
                }
            }
        case .notice(let notice):
            HStack(spacing: 7) {
                Image(systemName: notice.symbol).font(.system(size: 12, weight: .semibold))
                Text(verbatim: notice.title).font(.app(size: 12, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: NotchHome.noticeWing - inset - NotchDesign.contentInset, alignment: .leading)
        case .expanded where model.page != .music:
            NotchHomePageLabel(text: model.page.title)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var rightWing: some View {
        switch content {
        case .playing:
            if let track = model.track {
                // A still mark, not a pretend visualizer: live bars are a setting, in the player.
                Image(systemName: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(track.tint.opacity(0.9))
                    .frame(width: NotchHome.artSize)
                    .accessibilityLabel(Text("Playing"))
            }
        case .timer:
            if let running = NotchTimers.shared.running {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(verbatim: NotchTimers.clock(running.remaining(at: context.date)))
                        .font(.appMono(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .monospacedDigit()
                }
            }
        case .notice(let notice):
            if let detail = notice.detail {
                Text(verbatim: detail)
                    .font(.app(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
        case .expanded:
            NotchHomePageSelector(
                pages: NotchHomePage.available(hasTrack: model.track != nil), selection: model.page
            ) { page in
                model.page = page
            }
        default:
            EmptyView()
        }
    }

    /// One black surface, top to bottom. Glass below a black notch row read as a dark strip
    /// across the top of the card, and the cover fades into black more cleanly than into glass.
    private var background: some View {
        shape.fill(NotchDesign.solid)
    }

    private var rim: some View {
        shape.stroke(NotchDesign.rim, lineWidth: NotchDesign.rimWidth)
            .mask(LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35)))
            .opacity(content.isVisible ? 1 : 0)
            .frame(width: size.width, height: size.height)
    }
}

/// The cover, filling its half of the card. Without one, a quiet field in the cover's colour.
private struct NotchHomePoster: View {
    let image: NSImage?
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            } else {
                ZStack {
                    LinearGradient(
                        colors: [tint.opacity(0.25), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.system(size: 34, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The right half: names, a hairline of progress, and the controls. Times show only while the
/// pointer is on the line.
private struct NotchHomePlayer: View {
    let track: NotchTrack
    let modes: NotchPlaybackModes.State?
    let barsEnabled: Bool
    let onShuffle: () -> Void
    let onRepeat: () -> Void
    private var playback: PlaybackController { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Text(verbatim: track.title)
                    .font(.app(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if barsEnabled, track.isPlaying {
                    NotchLevelBars(color: track.tint, bars: 4, barWidth: 2.5, spacing: 2, maxHeight: 14)
                        .frame(width: 18, height: 14)
                }
            }
            Text(verbatim: track.artist)
                .font(.app(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .padding(.top, 2)

            NotchHomeProgress(track: track) { playback.seek(to: $0) }
                .frame(height: NotchHome.Card.progressHeight)
                .padding(.top, 14)

            HStack(spacing: 14) {
                NotchHomeControl(
                    symbol: "shuffle", size: 11, label: "Shuffle", lit: modes?.shuffle == true, action: onShuffle)
                NotchHomeControl(symbol: "backward.fill", size: 13, label: "Previous") {
                    playback.performAgentMediaAction("previous")
                }
                NotchHomeControl(
                    symbol: track.isPlaying ? "pause.fill" : "play.fill", size: 19,
                    label: track.isPlaying ? "Pause" : "Play"
                ) {
                    playback.performAgentMediaAction("toggle")
                }
                NotchHomeControl(symbol: "forward.fill", size: 13, label: "Next") {
                    playback.performAgentMediaAction("next")
                }
                NotchHomeControl(
                    symbol: modes?.repeatMode == .one ? "repeat.1" : "repeat", size: 11, label: "Repeat",
                    lit: modes.map { $0.repeatMode != .off } ?? false, action: onRepeat)
            }
            .frame(maxWidth: .infinity)
            .frame(height: NotchHome.Card.controlsHeight)
            .padding(.top, 6)
            Spacer(minLength: 0)
        }
        .padding(.leading, 4)
        .padding(.trailing, AgentComposer.panelInset)
        .padding(.bottom, NotchHome.Card.bottom)
    }
}

private struct NotchHomeArtwork: View {
    let image: NSImage?
    let size: CGFloat
    let radius: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.white.opacity(0.08)
                    Image(systemName: "music.note").font(.system(size: size * 0.42, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// A hairline you can click to jump. The times appear above it only while the pointer is on it;
/// the rest of the time the line says enough.
private struct NotchHomeProgress: View {
    let track: NotchTrack
    let onSeek: (Double) -> Void
    @State private var hovered = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let position = track.position(at: context.date) ?? 0
            let duration = track.duration ?? 0
            GeometryReader { geo in
                let fraction = duration > 0 ? min(1, position / duration) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14))
                    Capsule().fill(.white.opacity(hovered ? 0.95 : 0.75)).frame(
                        width: max(3, geo.size.width * fraction))
                }
                .frame(height: hovered ? 4 : 3)
                .frame(maxHeight: .infinity)
                .overlay(alignment: .top) {
                    if hovered, duration > 0 {
                        HStack {
                            Text(verbatim: NotchHome.clock(position))
                            Spacer()
                            Text(verbatim: NotchHome.clock(duration))
                        }
                        .font(.appMono(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .offset(y: -9)
                        .transition(.opacity)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    guard duration > 0 else { return }
                    onSeek(Double(location.x / max(geo.size.width, 1)) * duration)
                }
            }
        }
        .onHover { inside in withAnimation(.easeOut(duration: 0.15)) { hovered = inside } }
    }
}

private struct NotchHomeControl: View {
    let symbol: String
    let size: CGFloat
    let label: LocalizedStringKey
    /// Shuffle and repeat: lit while on.
    var lit: Bool? = nil
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 30, height: NotchHome.Card.controlsHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(lit == true ? .isSelected : [])
    }

    private var color: Color {
        if let lit { return lit ? AppTheme.Accent.primary : .white.opacity(hovered ? 0.8 : 0.45) }
        return .white.opacity(hovered ? 1 : 0.85)
    }
}

// MARK: - Bars

/// Bars driven by SystemAudioLevels, drawn as plain CALayers updated at 30 Hz. A SwiftUI
/// TimelineView or Canvas doing the same costs far more CPU for five rectangles.
struct NotchLevelBars: NSViewRepresentable {
    let color: Color
    let bars: Int
    let barWidth: CGFloat
    let spacing: CGFloat
    let maxHeight: CGFloat

    func makeNSView(context: Context) -> LevelBarsNSView {
        LevelBarsNSView(bars: bars, barWidth: barWidth, spacing: spacing, maxHeight: maxHeight)
    }

    func updateNSView(_ view: LevelBarsNSView, context: Context) {
        view.color = NSColor(color)
    }
}

final class LevelBarsNSView: NSView {
    var color: NSColor = .white {
        didSet { bars.forEach { $0.backgroundColor = color.cgColor } }
    }
    private let bars: [CALayer]
    private let barWidth: CGFloat
    private let spacing: CGFloat
    private let maxHeight: CGFloat
    private var timer: Timer?

    init(bars count: Int, barWidth: CGFloat, spacing: CGFloat, maxHeight: CGFloat) {
        self.barWidth = barWidth
        self.spacing = spacing
        self.maxHeight = maxHeight
        bars = (0..<count).map { _ in CALayer() }
        super.init(frame: .zero)
        wantsLayer = true
        for bar in bars {
            bar.cornerRadius = barWidth / 2
            bar.backgroundColor = color.cgColor
            layer?.addSublayer(bar)
        }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    /// Levels come in band order, bass first; with fewer bars than bands the highest band is
    /// dropped, since it is the one most songs barely move.
    private func tick() {
        let levels = SystemAudioLevels.shared.levels
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let total = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * spacing
        var x = (bounds.width - total) / 2
        for (index, bar) in bars.enumerated() {
            let level = index < levels.count ? CGFloat(levels[index]) : 0
            let height = max(barWidth, maxHeight * level)
            bar.frame = CGRect(x: x, y: (bounds.height - height) / 2, width: barWidth, height: height)
            x += barWidth + spacing
        }
        CATransaction.commit()
    }
}

// MARK: - Panel

final class NotchHomePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect, styleMask: [.nonactivatingPanel, .fullSizeContentView, .hudWindow],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        canHide = false
        // The idle tab's level: under Claude Code's cards and under the recorder.
        level = .statusBar + 1
        backgroundColor = .clear
        isOpaque = false
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

@MainActor
final class NotchHomeManager {
    private weak var uiManager: RecorderUIManager?
    private var panel: NotchHomePanel?
    private var model: NotchHomeModel?
    private var screen: NSScreen?
    private var hovered = false
    private var dropping = false
    private var cancellables: Set<AnyCancellable> = []
    private var resizeTask: Task<Void, Never>?
    private var pointerWatch: Timer?
    private var artworkCache: (key: String, image: NSImage?, tint: Color)?
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "NotchHome")

    init(uiManager: RecorderUIManager) {
        self.uiManager = uiManager
        PlaybackController.shared.$nowPlaying.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        uiManager.$isRecorderPanelVisible.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        uiManager.$isClaudeCodeCardVisible.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        NotchTimers.shared.$running.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        NotchTimers.shared.$finished.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        NotchDeviceAlerts.shared.$notice.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
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
        let enabled = NotchHome.isEnabled
        let wantsMusic = enabled && NotchHome.musicEnabled
        PlaybackController.shared.setNowPlayingWanted(wantsMusic)
        if enabled && NotchDeviceAlerts.isEnabled {
            NotchDeviceAlerts.shared.start()
        } else {
            NotchDeviceAlerts.shared.stop()
        }

        let track = wantsMusic ? makeTrack(PlaybackController.shared.nowPlaying) : nil
        let screen = self.screen ?? NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        let timers = NotchTimers.shared
        let content = NotchHome.content(
            enabled: enabled, hasNotch: screen != nil,
            blocked: uiManager.isRecorderPanelVisible || uiManager.isClaudeCodeCardVisible, hovered: hovered,
            dropping: dropping,
            notice: Self.notice(device: NotchDeviceAlerts.shared.notice, finished: timers.finished),
            timerRunning: timers.running != nil, musicPlaying: track?.isPlaying == true)

        if content == .hidden, hovered { setHovered(false) }
        apply(content, track: track, timerRunning: timers.running != nil, on: screen)

        // Listening turns on macOS's purple recording dot, so it happens only while the Music
        // page is open, and only when the setting is on.
        let showsBars =
            NotchHome.barsEnabled && track?.isPlaying == true && content == .expanded && model?.page == .music
        if showsBars { SystemAudioLevels.shared.start() } else { SystemAudioLevels.shared.stop() }

        if uiManager.isNotchHomeVisible != content.isVisible { uiManager.isNotchHomeVisible = content.isVisible }
    }

    /// A finished timer outranks a device: it is the one the user was waiting for.
    static func notice(device: NotchDeviceAlerts.Notice?, finished: NotchTimers.Finished?) -> NotchHome.Notice? {
        if let finished {
            return NotchHome.Notice(symbol: "bell.fill", title: finished.label, detail: finished.next?.label)
        }
        if let device { return NotchHome.Notice(symbol: device.symbol, title: device.title, detail: device.detail) }
        return nil
    }

    /// Files dragged over the notch open it on the shelf; it closes again once the pointer leaves.
    private func setDropTargeted(_ targeted: Bool) {
        guard targeted != dropping else { return }
        dropping = targeted
        model?.dropping = targeted
        if targeted {
            model?.page = .shelf
            setHovered(true)
        } else {
            refresh()
        }
    }

    private func makeTrack(_ payload: TrackInfo.Payload?) -> NotchTrack? {
        guard let payload, let title = payload.title, !title.isEmpty else { return nil }
        let key = payload.uniqueIdentifier + String(payload.artworkDataBase64?.count ?? 0)
        if artworkCache?.key != key {
            let image = payload.artworkDataBase64.flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:))
            artworkCache = (key, image, Self.tint(of: image))
        }
        let stamp = payload.timestampEpochMicros.map { Date(timeIntervalSince1970: $0 / 1_000_000) } ?? Date()
        return NotchTrack(
            id: payload.uniqueIdentifier, title: title, artist: payload.artist ?? payload.applicationName ?? "",
            isPlaying: payload.isPlaying == true, duration: payload.durationMicros.map { $0 / 1_000_000 },
            elapsed: payload.elapsedTimeMicros.map { $0 / 1_000_000 }, stamp: stamp,
            rate: payload.playbackRate ?? (payload.isPlaying == true ? 1 : 0), artwork: artworkCache?.image,
            tint: artworkCache?.tint ?? .white, bundleID: payload.bundleIdentifier)
    }

    /// The cover's average colour, lifted so a dark cover still gives bars you can see.
    static func tint(of image: NSImage?) -> Color {
        guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard
            let context = CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return .white }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let color = NSColor(
            red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        color.usingColorSpace(.deviceRGB)?.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return Color(
            nsColor: NSColor(hue: hue, saturation: min(saturation, 0.7), brightness: max(brightness, 0.85), alpha: 1))
    }

    // MARK: Hover

    private func setHovered(_ inside: Bool) {
        guard inside != hovered else { return }
        hovered = inside
        ActivityTrail.mark("notch home hover \(inside)")
        if inside {
            // mouseExited is not reliable on a panel that resizes under the pointer, so while
            // open the pointer itself is checked.
            pointerWatch?.invalidate()
            let watch = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkPointer() }
            }
            RunLoop.main.add(watch, forMode: .common)
            pointerWatch = watch
        } else {
            pointerWatch?.invalidate()
            pointerWatch = nil
        }
        refresh()
    }

    private func checkPointer() {
        guard let panel, hovered else { return }
        if !panel.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation) { setHovered(false) }
    }

    // MARK: Window

    private func apply(_ content: NotchHome.Content, track: NotchTrack?, timerRunning: Bool, on screen: NSScreen?) {
        if content == .hidden {
            guard let panel, let model, model.content != .hidden else { return }
            resizeTask?.cancel()
            model.content = .hidden
            resizeTask = Task { @MainActor [weak panel] in
                try? await Task.sleep(for: .seconds(NotchDesign.closeDuration))
                guard !Task.isCancelled else { return }
                panel?.orderOut(nil)
            }
            return
        }
        guard let screen else { return }
        if panel == nil { buildPanel(on: screen) }
        guard let panel, let model else { return }
        if model.track != track { model.track = track }
        if content == .expanded, model.content != .expanded {
            model.page = NotchHomePage.preferred(
                hasTrack: track != nil, timerRunning: timerRunning, dropping: dropping)
            readModes(of: track)
        }
        if model.page == .music, track == nil { model.page = .today }
        if panel.isVisible, model.content == content { return }
        resizeTask?.cancel()

        let target = NotchHome.size(for: content, notchWidth: model.notchWidth, notchHeight: model.notchHeight)
        let current = panel.frame.size
        let wasVisible = panel.isVisible && model.content != .hidden
        let grows = !wasVisible || (target.width >= current.width && target.height >= current.height)
        panel.hasShadow = content == .expanded
        if grows {
            panel.setFrame(NotchHome.frame(for: target, screenFrame: screen.frame), display: true)
            panel.orderFrontRegardless()
            model.content = content
        } else {
            model.content = content
            panel.orderFrontRegardless()
            resizeTask = Task { @MainActor [weak panel, weak self] in
                try? await Task.sleep(for: .seconds(NotchDesign.closeDuration))
                guard !Task.isCancelled, let panel, let screen = self?.screen else { return }
                panel.setFrame(NotchHome.frame(for: target, screenFrame: screen.frame), display: true)
            }
        }
    }

    /// Shuffle and repeat are read when the player opens, for the players that can say.
    private func readModes(of track: NotchTrack?) {
        model?.modes = nil
        guard NotchPlaybackModes.canReadState(of: track?.bundleID) else { return }
        Task { @MainActor [weak model] in
            let state = await NotchPlaybackModes.read(track?.bundleID)
            model?.modes = state
        }
    }

    private func buildPanel(on screen: NSScreen) {
        guard let metrics = NotchRecorderPanel.calculateWindowMetrics(on: screen) else { return }
        self.screen = screen
        let model = NotchHomeModel(notchWidth: metrics.notchWidth, notchHeight: metrics.notchHeight)
        let size = NotchHome.size(for: .bare, notchWidth: metrics.notchWidth, notchHeight: metrics.notchHeight)
        let panel = NotchHomePanel(contentRect: NotchHome.frame(for: size, screenFrame: screen.frame))
        let view = NotchHomeView(
            model: model,
            onHover: { [weak self] inside in
                guard inside else { return }  // leaving is decided by checkPointer
                self?.setHovered(true)
            },
            onShuffle: { [weak model] in
                guard let model else { return }
                Task { @MainActor in
                    let state = await NotchPlaybackModes.toggleShuffle(model.track?.bundleID, from: model.modes)
                    if let state { model.modes = state }
                }
            },
            onRepeat: { [weak model] in
                guard let model else { return }
                Task { @MainActor in
                    let state = await NotchPlaybackModes.cycleRepeat(model.track?.bundleID, from: model.modes)
                    if let state { model.modes = state }
                }
            },
            onDropTargeted: { [weak self] targeted in self?.setDropTargeted(targeted) })
        panel.contentView = NotchRecorderHostingController(rootView: view).view
        self.model = model
        self.panel = panel
        // The live bars depend on the page, so a page switch is a refresh.
        model.$page.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        logger.notice("Notch home built")
    }

    private func destroyPanel() {
        resizeTask?.cancel()
        pointerWatch?.invalidate()
        pointerWatch = nil
        hovered = false
        dropping = false
        panel?.orderOut(nil)
        panel = nil
        model = nil
        screen = nil
    }
}
