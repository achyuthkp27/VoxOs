import AppKit
import Combine
import MediaRemoteAdapter
import QuartzCore
import SwiftUI
import os

/// The notch between dictations. Collapsed it says one thing at a time; hovered (or with files
/// dragged toward it) it opens into a small card with five pages: Music, Calendar, Reminders,
/// Pomodoro and Shelf.
///
/// Collapsed, in order: a passing notice (a device connected, a timer finished, the battery), the
/// next meeting, a microphone or camera in use, a running timer, the playing track; otherwise a
/// notch-sized black target that disappears into the hardware notch and is only there to be
/// hovered or dropped on.
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
    /// A microphone and a camera, or an app's icon.
    static var privacyWing: CGFloat { wing(holding: 36) }
    /// How far round the open card a dragged file opens the shelf.
    static let dragMargin: CGFloat = 24

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
        /// The cover tile: the card's height less its top and bottom insets.
        static var coverSize: CGFloat { height - top - bottom }
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
        /// A meeting about to start: a countdown, and Join when it has a link.
        case meeting(NotchToday.Event)
        /// Another app has the microphone or a camera; a click on the microphone mutes it.
        case privacy(NotchPrivacy.State)
        case expanded

        /// Shows something beyond the hardware notch.
        var isVisible: Bool { self != .hidden && self != .bare }
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.notchHomeEnabled) }
    static var musicEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.notchMusicEnabled) }
    static var barsEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.notchMusicBarsEnabled) }
    static var barsOnBattery: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.notchMusicBarsOnBattery) }

    /// Live bars listen only while the setting is on, Low Power Mode is off, and the Mac is on its
    /// adapter or the user lets them run on battery. Otherwise the bars are ambient.
    static func liveBars(enabled: Bool, lowPowerMode: Bool, onBattery: Bool, allowedOnBattery: Bool) -> Bool {
        enabled && !lowPowerMode && (!onBattery || allowedOnBattery)
    }
    static var showsInFullScreen: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.notchHomeInFullScreen) }
    static var meetingsEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.notchMeetingsEnabled) }

    /// Collapsed, in order: a passing notice, the next meeting, a microphone or camera in use, a
    /// running timer, the playing track.
    static func content(
        enabled: Bool, hasNotch: Bool, blocked: Bool, hovered: Bool, dropping: Bool, notice: Notice?,
        timerRunning: Bool, musicPlaying: Bool, meeting: NotchToday.Event? = nil, privacy: NotchPrivacy.State? = nil
    ) -> Content {
        guard enabled, hasNotch, !blocked else { return .hidden }
        if hovered || dropping { return .expanded }
        if let notice { return .notice(notice) }
        if let meeting { return .meeting(meeting) }
        if let privacy, privacy.isActive { return .privacy(privacy) }
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
        case .notice, .meeting:
            return CGSize(width: notchWidth + noticeWing * 2, height: notchHeight)
        case .privacy:
            return CGSize(width: notchWidth + privacyWing * 2, height: notchHeight)
        case .expanded:
            return CGSize(
                width: max(NotchDesign.expandedWidth, notchWidth + wing * 2), height: notchHeight + Card.height)
        }
    }

    static func radii(for content: Content) -> NotchDesign.Radii {
        switch content {
        case .hidden, .bare: return NotchDesign.resting
        case .playing, .timer, .notice, .meeting, .privacy: return NotchDesign.listening
        case .expanded: return NotchDesign.expanded
        }
    }

    static func frame(for size: CGSize, screenFrame: CGRect) -> CGRect {
        ClaudeCodeNotch.frame(for: size, screenFrame: screenFrame)
    }

    /// How long the pointer may be outside the open card before it closes.
    static let leaveGrace: TimeInterval = 0.22

    /// A light tap from the trackpad when the notch opens under the pointer or takes a drop: the
    /// "you arrived on something" pattern, timed to the frame that shows it. Nothing on a mouse.
    @MainActor
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
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
    /// The track shown: the one picked with the dots, or the one playing.
    @Published var track: NotchTrack?
    /// Every player with a track, in a stable order for the dots.
    @Published var tracks: [NotchTrack] = []
    /// Shuffle and repeat as the player reports them; nil when it cannot say.
    @Published var modes: NotchPlaybackModes.State?
    @Published var page: NotchHomePage = .today
    /// The last page change went forward (a swipe to the left), for the slide's direction.
    @Published var pagedForward = true
    /// Files are being dragged over the notch.
    @Published var dropping = false
    /// The bars follow the real output (see `NotchHome.liveBars`); otherwise they are ambient.
    @Published var liveBars = false
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
    let onSelectTrack: (String?) -> Void
    /// Next page (true) or previous (false).
    let onPage: (Bool) -> Void
    /// A click-drag ended: where it started (window x) and how far it went.
    let onDrag: (CGFloat, CGSize) -> Void
    let onToggleMute: () -> Void
    let onJoin: (NotchToday.Event) -> Void
    @AppStorage(DefaultsKeys.notchMusicBarsEnabled) private var barsEnabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var content: NotchHome.Content { model.content }
    private var size: CGSize {
        NotchHome.size(for: content, notchWidth: model.notchWidth, notchHeight: model.notchHeight)
    }
    private var shape: NotchShape { NotchShape(NotchHome.radii(for: content)) }
    private var inset: CGFloat { NotchHome.radii(for: content).shoulder + NotchDesign.contentInset }
    private var notchRect: CGSize { CGSize(width: model.notchWidth, height: model.notchHeight) }

    /// The top strip of the hardware notch's span, centred in the window. Browser tabs sit right
    /// under the notch, so a pointer heading for them must not open the card; one pushed against
    /// the top of the screen stops in this strip by itself.
    static func opensAt(_ point: CGPoint, width: CGFloat, notch: CGSize) -> Bool {
        let half = notch.width / 2 + 6
        return abs(point.x - width / 2) <= half && point.y <= notch.height * hotStrip
    }

    /// The share of the notch's height, from the top of the screen, that opens the card.
    static let hotStrip: CGFloat = 0.2

    var body: some View {
        ZStack(alignment: .topLeading) {
            background
            VStack(spacing: 0) {
                notchRow
                if content == .expanded {
                    page
                        .id(model.page)
                        .frame(height: NotchHome.Card.height, alignment: .top)
                        .transition(.push(from: model.pagedForward ? .trailing : .leading))
                }
            }
            if content == .expanded, model.page == .music, model.tracks.count > 1 {
                playerDots
            }
            rim
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipShape(shape)
        .contentShape(shape)
        // On the drawn shape: SwiftUI sends no hover to a clear view. Only the notch itself opens
        // it; the band's wings hold the cover and the bars, and pass under the pointer on the way
        // to the menu bar.
        .onContinuousHover(coordinateSpace: .local) { phase in
            guard case .active(let point) = phase else { return }
            if content == .expanded || Self.opensAt(point, width: size.width, notch: notchRect) { onHover(true) }
        }
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .simultaneousGesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .local)
                .onEnded { value in onDrag(value.startLocation.x, value.translation) }
        )
        .dropDestination(for: URL.self) { urls, _ in
            NotchShelf.shared.add(urls)
            if !urls.isEmpty { NotchHome.tap() }
            return !urls.isEmpty
        } isTargeted: { targeted in
            onDropTargeted(targeted)
        }
        .animation(
            reduceMotion ? nil : (content == .expanded ? NotchDesign.openAnimation : NotchDesign.closeAnimation),
            value: content
        )
        .animation(reduceMotion ? nil : NotchDesign.sizeAnimation, value: model.page)
    }

    /// One dot per player, down the left edge over the cover; a two-finger scroll up or down on
    /// the card moves between them too.
    private var playerDots: some View {
        VStack(spacing: 2) {
            ForEach(model.tracks, id: \.bundleID) { track in
                let selected = track.bundleID == model.track?.bundleID
                Button {
                    onSelectTrack(track.bundleID)
                } label: {
                    Circle()
                        .fill(.white.opacity(selected ? 0.9 : 0.3))
                        .frame(width: 4, height: 4)
                        .frame(width: 14, height: 9)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(track.title)
                .accessibilityLabel(Text(verbatim: track.title))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(height: NotchHome.Card.height)
        .padding(.leading, 8)
        .offset(y: model.notchHeight)
    }

    @ViewBuilder
    private var page: some View {
        switch model.page {
        case .music:
            if let track = model.track {
                NotchHomePlayer(
                    track: track, modes: model.modes, liveBars: model.liveBars, onShuffle: onShuffle,
                    onRepeat: onRepeat, onToggleBars: { barsEnabled.toggle() })
            }
        case .timer:
            NotchTimerPage(timers: .shared)
        case .today:
            NotchTodayPage(today: .shared)
        case .reminders:
            NotchRemindersPage(reminders: .shared)
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
            if let track = model.track {
                NotchHomeArtwork(image: track.artwork, size: NotchHome.artSize, radius: 5)
                    .overlay(alignment: .leading) {
                        // More than one player: a hint that hovering and scrolling switches.
                        if model.tracks.count > 1 { bandDots.offset(x: -8) }
                    }
            }
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
        case .meeting(let meeting):
            HStack(spacing: 7) {
                Image(systemName: meeting.joinURL == nil ? "calendar" : "video.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(meeting.color)
                Text(verbatim: meeting.title).font(.app(size: 12, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: NotchHome.noticeWing - inset - NotchDesign.contentInset, alignment: .leading)
        case .privacy(let privacy):
            NotchPrivacyGlyphs(state: privacy, onToggleMute: onToggleMute)
        case .expanded:
            // The player's name on the Music page (several can play at once), the page's elsewhere.
            NotchHomePageLabel(
                text: model.page == .music
                    ? (NotchHomeApp.name(for: model.track?.bundleID) ?? model.page.title) : model.page.title)
        default:
            EmptyView()
        }
    }

    /// Tiny dots beside the cover in the collapsed band, one per player, the shown one bright.
    private var bandDots: some View {
        VStack(spacing: 2.5) {
            ForEach(model.tracks.prefix(4), id: \.bundleID) { track in
                Circle()
                    .fill(.white.opacity(track.bundleID == model.track?.bundleID ? 0.85 : 0.3))
                    .frame(width: 3, height: 3)
            }
        }
        .accessibilityLabel(Text("\(model.tracks.count) players"))
    }

    @ViewBuilder
    private var rightWing: some View {
        switch content {
        case .playing:
            if let track = model.track {
                // Live when the setting is on; otherwise ambient motion that listens to nothing,
                // so no recording dot.
                NotchLevelBars(
                    color: track.tint, bars: 4, barWidth: 3, spacing: 2.5, maxHeight: 14,
                    source: model.liveBars ? .live : .ambient
                )
                .frame(width: NotchHome.artSize, height: 16)
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
        case .meeting(let meeting):
            HStack(spacing: 6) {
                // Meetings start on the minute, so a minute's tick keeps the count right.
                TimelineView(.everyMinute) { context in
                    Text(verbatim: NotchToday.countdown(to: meeting.start, now: context.date))
                        .font(.appMono(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .monospacedDigit()
                }
                if meeting.joinURL != nil {
                    NotchJoinButton { onJoin(meeting) }
                }
            }
        case .privacy(let privacy):
            if let icon = NotchHomeApp.icon(for: privacy.microphoneApp) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .help(NotchHomeApp.name(for: privacy.microphoneApp) ?? "")
                    .accessibilityLabel(Text(verbatim: NotchHomeApp.name(for: privacy.microphoneApp) ?? ""))
            }
        case .expanded:
            NotchHomePageButton(page: model.page) { onPage(true) }
        default:
            EmptyView()
        }
    }

    /// One black surface, top to bottom, and fully opaque while open: glass below a black notch
    /// row read as a dark strip, and a card over a document must not let its text through.
    private var background: some View {
        shape.fill(content == .expanded ? Color(red: 0, green: 0, blue: 2 / 255) : NotchDesign.solid)
    }

    private var rim: some View {
        shape.stroke(NotchDesign.rim, lineWidth: NotchDesign.rimWidth)
            .mask(LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35)))
            .opacity(content.isVisible ? 1 : 0)
            .frame(width: size.width, height: size.height)
    }
}

/// The microphone (a click mutes or unmutes it) and the camera, in macOS's own indicator colours.
private struct NotchPrivacyGlyphs: View {
    let state: NotchPrivacy.State
    let onToggleMute: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 7) {
            if state.microphone {
                Button(action: onToggleMute) {
                    Image(systemName: state.muted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(state.muted ? ClaudeCodeNotch.failedColor : .orange)
                        .opacity(hovered ? 0.8 : 1)
                        .frame(width: 16, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .help(state.muted ? "Microphone muted. Click to unmute." : "Microphone in use. Click to mute.")
                .accessibilityLabel(Text(state.muted ? "Unmute the microphone" : "Mute the microphone"))
            }
            if state.camera {
                Image(systemName: "video.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ClaudeCodeNotch.doneColor)
                    .accessibilityLabel(Text("Camera in use"))
            }
        }
    }
}

/// "Join", on the meeting band and beside a meeting on the Calendar page.
struct NotchJoinButton: View {
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text("Join")
                .font(.app(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .frame(height: 18)
                .background(Capsule().fill(ClaudeCodeNotch.doneColor.opacity(hovered ? 0.75 : 0.55)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(Text("Join the meeting"))
    }
}

/// The player app's name and icon, for the Music page's label and a track without a cover.
@MainActor
enum NotchHomeApp {
    private static var names: [String: String] = [:]
    private static var icons: [String: NSImage] = [:]

    static func name(for bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        if let name = names[bundleID] { return name }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        names[bundleID] = name
        return name
    }

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let icon = icons[bundleID] { return icon }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = icon
        return icon
    }
}

/// The cover as a tile. Without one, the player's own icon on a quiet tile in the cover's colour
/// (a browser playing YouTube has no cover to give).
private struct NotchHomeCover: View {
    let track: NotchTrack
    let size: CGFloat
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 14, style: .continuous) }

    var body: some View {
        Group {
            if let artwork = track.artwork {
                Image(nsImage: artwork).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [track.tint.opacity(0.28), track.tint.opacity(0.08)], startPoint: .topLeading,
                        endPoint: .bottomTrailing)
                    if let icon = NotchHomeApp.icon(for: track.bundleID) {
                        Image(nsImage: icon).resizable().frame(width: size * 0.46, height: size * 0.46)
                    } else {
                        Image(systemName: "music.note").font(.system(size: size * 0.22, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

/// The cover on the left; names, a hairline of progress and the controls beside it, top and
/// bottom aligned with the cover. Times show only while the pointer is on the line.
private struct NotchHomePlayer: View {
    let track: NotchTrack
    let modes: NotchPlaybackModes.State?
    let liveBars: Bool
    let onShuffle: () -> Void
    let onRepeat: () -> Void
    let onToggleBars: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            NotchHomeCover(track: track, size: NotchHome.Card.coverSize)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: track.title)
                            .font(.app(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(verbatim: track.artist)
                            .font(.app(size: 12))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if track.isPlaying {
                        // A click switches Live Music Bars, so they need not live in Settings to
                        // be tried; ambient bars are dimmer, so the switch shows.
                        Button(action: onToggleBars) {
                            NotchLevelBars(
                                color: track.tint, bars: 4, barWidth: 2.5, spacing: 2, maxHeight: 14,
                                source: liveBars ? .live : .ambient
                            )
                            .opacity(liveBars ? 1 : 0.55)
                            .frame(width: 18, height: 16)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(liveBars ? "Live music bars: on" : "Live music bars: off")
                        .accessibilityLabel(Text(liveBars ? "Turn live music bars off" : "Turn live music bars on"))
                    }
                }
                .padding(.top, 4)

                Spacer(minLength: 0)

                NotchHomeProgress(track: track) { NotchPlayers.perform(.seek($0), on: track.bundleID) }
                    .frame(height: NotchHome.Card.progressHeight)

                HStack(spacing: 0) {
                    NotchHomeControl(
                        symbol: "shuffle", size: 11, label: "Shuffle", lit: modes?.shuffle == true, action: onShuffle)
                    Spacer(minLength: 0)
                    NotchHomeControl(symbol: "backward.fill", size: 13, label: "Previous") {
                        NotchPlayers.perform(.previous, on: track.bundleID)
                    }
                    Spacer(minLength: 0)
                    NotchHomeControl(
                        symbol: track.isPlaying ? "pause.fill" : "play.fill", size: 19,
                        label: track.isPlaying ? "Pause" : "Play"
                    ) {
                        NotchPlayers.perform(.toggle, on: track.bundleID)
                    }
                    Spacer(minLength: 0)
                    NotchHomeControl(symbol: "forward.fill", size: 13, label: "Next") {
                        NotchPlayers.perform(.next, on: track.bundleID)
                    }
                    Spacer(minLength: 0)
                    NotchHomeControl(
                        symbol: modes?.repeatMode == .one ? "repeat.1" : "repeat", size: 11, label: "Repeat",
                        lit: modes.map { $0.repeatMode != .off } ?? false, action: onRepeat)
                }
                .frame(height: NotchHome.Card.controlsHeight)
                .padding(.top, 4)
            }
            .frame(height: NotchHome.Card.coverSize)
        }
        .padding(.top, NotchHome.Card.top)
        .padding(.horizontal, AgentComposer.panelInset)
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

/// Bars driven by SystemAudioLevels, drawn as plain CALayers updated by a timer (see
/// `LevelBarsNSView.interval`). A SwiftUI TimelineView or Canvas doing the same costs far more CPU
/// for five rectangles.
struct NotchLevelBars: NSViewRepresentable {
    enum Source {
        /// The Mac's real output, from SystemAudioLevels.
        case live
        /// A slow, organic motion that only says "playing": nothing is listened to.
        case ambient
    }

    let color: Color
    let bars: Int
    let barWidth: CGFloat
    let spacing: CGFloat
    let maxHeight: CGFloat
    var source: Source = .live

    func makeNSView(context: Context) -> LevelBarsNSView {
        LevelBarsNSView(bars: bars, barWidth: barWidth, spacing: spacing, maxHeight: maxHeight)
    }

    func updateNSView(_ view: LevelBarsNSView, context: Context) {
        view.color = NSColor(color)
        view.source = source
    }

    /// Each bar drifts on two slow sines at its own pace, so the bars never move in step and never
    /// repeat in a way the eye catches. 0.15…1.
    static func ambientLevels(count: Int, at time: TimeInterval) -> [Float] {
        (0..<count).map { index in
            let i = Double(index)
            let value =
                0.55 + 0.28 * sin(time * (5.1 + i * 1.3) + i * 1.7) + 0.17 * sin(time * (8.3 + i * 0.9) + i * 2.9)
            return Float(min(1, max(0.15, value)))
        }
    }
}

final class LevelBarsNSView: NSView {
    var color: NSColor = .white {
        didSet { bars.forEach { $0.backgroundColor = color.cgColor } }
    }
    var source: NotchLevelBars.Source = .live {
        didSet { if source != oldValue { schedule() } }
    }
    private let bars: [CALayer]
    private let barWidth: CGFloat
    private let spacing: CGFloat
    private let maxHeight: CGFloat
    private var timer: Timer?
    var isTicking: Bool { timer?.isValid == true }
    private var occlusionWatch: NSObjectProtocol?
    private var awayWatch: AnyCancellable?

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

    deinit {
        if let occlusionWatch { NotificationCenter.default.removeObserver(occlusionWatch) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionWatch { NotificationCenter.default.removeObserver(occlusionWatch) }
        occlusionWatch = nil
        awayWatch = nil
        if let window {
            occlusionWatch = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in self?.schedule() }
            awayWatch = PowerState.shared.$isAway.dropFirst().receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.schedule() }
        }
        schedule()
    }

    /// Live bars follow the music at 30 frames a second; ambient motion is slow enough for 20.
    static func interval(for source: NotchLevelBars.Source) -> TimeInterval {
        source == .live ? 1.0 / 30 : 1.0 / 20
    }

    /// Ticks only while the bars can be seen: in a window that is on screen, with the displays
    /// awake and the screen unlocked.
    private func schedule() {
        let visible =
            window?.occlusionState.contains(.visible) == true && !PowerState.shared.isAway
        guard visible else {
            timer?.invalidate()
            timer = nil
            return
        }
        let interval = Self.interval(for: source)
        if let timer, timer.isValid, timer.timeInterval == interval { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        // A little slack lets macOS fold these wake-ups into the display's own.
        timer.tolerance = interval * 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    /// Levels come in band order, bass first; with fewer bars than bands the highest band is
    /// dropped, since it is the one most songs barely move.
    private func tick() {
        let levels =
            source == .live
            ? SystemAudioLevels.shared.levels
            : NotchLevelBars.ambientLevels(count: bars.count, at: CACurrentMediaTime())
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
    /// The band a swipe put away; it stays away until the band would say something else.
    private var dismissedBand: String?
    /// The player picked with the dots or a scroll, by bundle id.
    private var selectedPlayer: String?
    private var scrollMonitor: Any?
    /// When the pointer was first seen outside the open card; nil while it is inside.
    private var pointerLeftAt: Date?
    /// The widest band that covers nothing in the menu bar; nil while unknown.
    private var allowedWing: CGFloat?
    private var clearanceMeasured: Date?
    /// Only the newest measurement counts; two can be in flight when the front app changes.
    private var clearanceRequest = 0
    private var gesture: (startX: CGFloat, width: CGFloat, dx: CGFloat, dy: CGFloat)?
    private var cancellables: Set<AnyCancellable> = []
    private var resizeTask: Task<Void, Never>?
    private var pointerWatch: Timer?
    private var artworkCache: (key: String, image: NSImage?, tint: Color)?
    /// Files dragged in another app, seen through a global mouse monitor (see `globalMouse`).
    private var dragMonitor: Any?
    private var dragChangeCount = 0
    /// A dragged file reached the notch's area and opened the card on the shelf.
    private var shelfForDrag = false
    private var meetingsWatched = false
    private var meetingWatch: AnyCancellable?
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
        NotchPlayers.shared.$entries.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        NotchPrivacy.shared.$state.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        // Entering or leaving a full-screen app is a Space change.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        // Another app in front brings other menus, which may reach further toward the notch.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.clearanceMeasured = nil
                self?.refresh()
            }
            .store(in: &cancellables)
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if let self, let panel = self.panel, event.window === panel { self.handleScroll(event, in: panel) }
            return event
        }
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        // Battery, Low Power Mode, displays asleep or the screen locked.
        PowerState.shared.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh() }
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
        if wantsMusic { NotchPlayers.shared.start() } else { NotchPlayers.shared.stop() }
        if enabled && NotchDeviceAlerts.isEnabled {
            NotchDeviceAlerts.shared.start()
        } else {
            NotchDeviceAlerts.shared.stop()
        }
        if enabled && NotchPrivacy.isEnabled { NotchPrivacy.shared.start() } else { NotchPrivacy.shared.stop() }
        let meeting = watchMeetings(enabled && NotchHome.meetingsEnabled && NotchToday.accessGranted)
        watchDrags(enabled)

        let tracks = wantsMusic ? makeTracks() : []
        let screenForState = self.screen ?? NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        let hiddenForFullScreen =
            !NotchHome.showsInFullScreen && screenForState.map(Self.frontAppIsFullScreen(on:)) == true
        let track = Self.shown(tracks, selected: selectedPlayer)
        let screen = self.screen ?? NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
        let timers = NotchTimers.shared
        var content = NotchHome.content(
            enabled: enabled && !hiddenForFullScreen, hasNotch: screen != nil,
            blocked: uiManager.isRecorderPanelVisible || uiManager.isClaudeCodeCardVisible, hovered: hovered,
            dropping: dropping,
            notice: Self.notice(device: NotchDeviceAlerts.shared.notice, finished: timers.finished),
            timerRunning: timers.running != nil, musicPlaying: track?.isPlaying == true, meeting: meeting,
            privacy: NotchPrivacy.shared.state)
        let band = Self.bandKey(content, track: track, timer: timers.running)
        if band != nil, band == dismissedBand { content = .bare }
        if let screen { measureClearance(on: screen) }
        if !Self.fits(content, allowedWing: allowedWing) { content = .bare }

        if content == .hidden, hovered { setHovered(false) }
        model?.tracks = tracks
        apply(content, track: track, timerRunning: timers.running != nil, on: screen)

        // Listening turns on macOS's purple recording dot, so it happens only when live bars are
        // allowed, and only while they are on screen (in the band or on the open Music page) and
        // someone can see them.
        let power = PowerState.shared
        let liveBars = NotchHome.liveBars(
            enabled: NotchHome.barsEnabled, lowPowerMode: power.lowPowerMode, onBattery: power.onBattery,
            allowedOnBattery: NotchHome.barsOnBattery)
        if model?.liveBars != liveBars { model?.liveBars = liveBars }
        let playing = track?.isPlaying == true && !power.isAway
        let showsBars =
            liveBars && playing && (content == .playing || (content == .expanded && model?.page == .music))
        if showsBars {
            SystemAudioLevels.shared.start()
        } else {
            // While live bars are allowed they are likely back in a moment: the card opening over
            // the band, or a player that flickers to paused as a track starts (measured: the tap
            // was built twice within 1.3 s without this). Turned off, the tap goes at once.
            SystemAudioLevels.shared.stop(linger: liveBars ? 3 : 0)
        }

        if uiManager.isNotchHomeVisible != content.isVisible { uiManager.isNotchHomeVisible = content.isVisible }
    }

    /// The meeting countdown runs only while wanted and the calendar may be read; the calendar is
    /// not touched otherwise, so nothing asks for access from here.
    private func watchMeetings(_ wanted: Bool) -> NotchToday.Event? {
        if wanted != meetingsWatched {
            meetingsWatched = wanted
            if wanted, meetingWatch == nil {
                meetingWatch = NotchToday.shared.$meeting.dropFirst().receive(on: RunLoop.main)
                    .sink { [weak self] _ in self?.refresh() }
            }
            NotchToday.shared.watchMeetings(wanted)
        }
        return wanted ? NotchToday.shared.meeting : nil
    }

    /// A file dragged in another app toward the notch opens the shelf before it gets there: the
    /// hardware notch alone is a small target to find with a file in hand. A global monitor sees
    /// other apps' events only; a drag from VoxOS's own windows is over them already.
    private func watchDrags(_ wanted: Bool) {
        if wanted, dragMonitor == nil, !ProcessIdentity.isTestHost {
            dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) {
                [weak self] event in
                MainActor.assumeIsolated { self?.globalMouse(event) }
            }
        } else if !wanted, let dragMonitor {
            NSEvent.removeMonitor(dragMonitor)
            self.dragMonitor = nil
        }
    }

    /// The drag pasteboard's count is read when the button goes down, so only a drag that wrote
    /// to it since (a real drag, not a window move or a text selection) counts, once.
    private func globalMouse(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            dragChangeCount = NSPasteboard(name: .drag).changeCount
        case .leftMouseDragged:
            guard !hovered, !dropping, let zone = dragZone(), zone.contains(NSEvent.mouseLocation) else { return }
            let board = NSPasteboard(name: .drag)
            guard board.changeCount != dragChangeCount else { return }
            dragChangeCount = board.changeCount
            guard board.types?.contains(.fileURL) == true else { return }
            ActivityTrail.mark("notch home shelf opened for a drag")
            shelfForDrag = true
            setHovered(true)
        default:
            break
        }
    }

    /// The open card's own frame and a margin round it, so the card opens under the pointer and
    /// the file is dropped on it.
    private func dragZone() -> CGRect? {
        guard let model, let screen, model.content != .hidden else { return nil }
        let size = NotchHome.size(for: .expanded, notchWidth: model.notchWidth, notchHeight: model.notchHeight)
        return NotchHome.frame(for: size, screenFrame: screen.frame)
            .insetBy(dx: -NotchHome.dragMargin, dy: -NotchHome.dragMargin)
    }

    /// The front app fills the notched screen: a full-screen video, game or app, where the menu
    /// bar is hidden and the notch is best left alone. Window bounds need no permission.
    static func frontAppIsFullScreen(on screen: NSScreen) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return false }
        return list.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? Int32) == front,
                (window[kCGWindowLayer as String] as? Int) == 0,
                let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                let width = bounds["Width"], let height = bounds["Height"]
            else { return false }
            return width >= screen.frame.width && height >= screen.frame.height
        }
    }

    /// A band that lasts (music, a timer) is drawn only where it covers nothing in the menu bar.
    /// A notice is gone in seconds, so it may.
    nonisolated static func fits(_ content: NotchHome.Content, allowedWing: CGFloat?) -> Bool {
        guard let allowedWing else { return true }
        switch content {
        case .playing: return allowedWing >= NotchHome.wing
        case .timer: return allowedWing >= NotchHome.timerWing
        case .privacy: return allowedWing >= NotchHome.privacyWing
        // A meeting is said for minutes, then gone, like a notice.
        default: return true
        }
    }

    /// Re-measured at most every ten seconds, and when another app comes to the front; a refresh
    /// uses the last result meanwhile, and a new result refreshes again.
    private func measureClearance(on screen: NSScreen) {
        if let measured = clearanceMeasured, Date().timeIntervalSince(measured) < 10 { return }
        clearanceMeasured = Date()
        let notchWidth = model?.notchWidth ?? NotchRecorderPanel.calculateWindowMetrics(on: screen)?.notchWidth ?? 185
        let notchMinX = screen.frame.midX - notchWidth / 2
        let notchMaxX = screen.frame.midX + notchWidth / 2
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }
            .map(\.processIdentifier)
        clearanceRequest += 1
        let request = clearanceRequest
        Task { @MainActor [weak self] in
            let measured = await NotchMenuBarClearance.measure(
                notchMinX: notchMinX, notchMaxX: notchMaxX, front: front, apps: apps)
            guard let self, request == self.clearanceRequest, measured.wing != self.allowedWing else { return }
            self.allowedWing = measured.wing
            self.logger.notice(
                "Notch home: room beside the notch \(measured.wing.map { String(Int($0)) } ?? "unknown", privacy: .public) pt, limited by \(measured.limitedBy, privacy: .public)"
            )
            self.refresh()
        }
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

    /// MediaRemote's player and every player followed directly, one each; MediaRemote's wins
    /// when both name the same app, since it brings the cover and an exact position.
    private func makeTracks() -> [NotchTrack] {
        var tracks: [NotchTrack] = []
        if let remote = makeTrack(PlaybackController.shared.nowPlaying) { tracks.append(remote) }
        for entry in NotchPlayers.shared.entries.values where !tracks.contains(where: { $0.bundleID == entry.bundleID })
        {
            tracks.append(
                NotchTrack(
                    id: entry.trackKey, title: entry.title, artist: entry.artist, isPlaying: entry.isPlaying,
                    duration: entry.duration, elapsed: entry.position, stamp: entry.stamp,
                    rate: entry.isPlaying ? 1 : 0, artwork: entry.artwork, tint: Self.tint(of: entry.artwork),
                    bundleID: entry.bundleID))
        }
        return tracks.sorted { ($0.bundleID ?? "") < ($1.bundleID ?? "") }
    }

    /// The player picked with the dots while it still has a track; otherwise one that is
    /// playing; otherwise the first.
    nonisolated static func shown(_ tracks: [NotchTrack], selected: String?) -> NotchTrack? {
        if let selected, let picked = tracks.first(where: { $0.bundleID == selected }) { return picked }
        return tracks.first(where: \.isPlaying) ?? tracks.first
    }

    /// What a collapsed band is about, so a swipe can put away this band and not the next one.
    nonisolated static func bandKey(_ content: NotchHome.Content, track: NotchTrack?, timer: NotchTimer?) -> String? {
        switch content {
        case .playing: return "playing:" + (track?.id ?? "")
        case .timer: return "timer:\(timer?.ends.timeIntervalSince1970 ?? 0)"
        case .notice(let notice): return "notice:\(notice.title)|\(notice.detail ?? "")"
        case .meeting(let meeting): return "meeting:\(meeting.id)"
        // Not the mute: muting must not bring back a band that was put away.
        case .privacy(let privacy):
            return "privacy:\(privacy.microphone)|\(privacy.camera)|\(privacy.microphoneApp ?? "")"
        default: return nil
        }
    }

    enum Swipe: Equatable {
        case dismiss
        /// Outward from the notch: brings back a band that was swiped away.
        case restore
        case nextPage
        case previousPage
        case nextPlayer
        case previousPlayer
        case none
    }

    /// Open: sideways turns the page (fingers left for the next), up and down moves between
    /// players. Collapsed: fingers moving toward the middle of the notch put the band away —
    /// right to left on its right half, left to right on its left half — and moving outward
    /// brings it back.
    nonisolated static func swipe(
        startX: CGFloat, width: CGFloat, fingerDX: CGFloat, fingerDY: CGFloat, expanded: Bool,
        threshold: CGFloat = 36
    ) -> Swipe {
        if abs(fingerDX) >= abs(fingerDY) {
            guard abs(fingerDX) >= threshold else { return .none }
            if expanded { return fingerDX < 0 ? .nextPage : .previousPage }
            let onRight = startX > width / 2
            return (onRight && fingerDX < 0) || (!onRight && fingerDX > 0) ? .dismiss : .restore
        }
        guard expanded, abs(fingerDY) >= threshold else { return .none }
        return fingerDY < 0 ? .nextPlayer : .previousPlayer
    }

    /// The page after (or before) `page` among those available, wrapping round.
    nonisolated static func page(after page: NotchHomePage, forward: Bool, hasTrack: Bool) -> NotchHomePage {
        let pages = NotchHomePage.available(hasTrack: hasTrack)
        guard let index = pages.firstIndex(of: page) else { return pages.first ?? page }
        return pages[(index + (forward ? 1 : -1) + pages.count) % pages.count]
    }

    private func handleScroll(_ event: NSEvent, in panel: NSPanel) {
        // Natural scrolling flips the deltas; turned back here, they follow the fingers.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        switch event.phase {
        case .began:
            gesture = (event.locationInWindow.x, panel.frame.width, 0, 0)
        case .changed:
            gesture?.dx += event.scrollingDeltaX * sign
            gesture?.dy += event.scrollingDeltaY * sign
        case .ended, .cancelled:
            guard let gesture else { return }
            self.gesture = nil
            perform(
                Self.swipe(
                    startX: gesture.startX, width: gesture.width, fingerDX: gesture.dx, fingerDY: gesture.dy,
                    expanded: model?.content == .expanded))
        default:
            break
        }
    }

    private func perform(_ swipe: Swipe) {
        guard let model else { return }
        switch swipe {
        case .dismiss:
            guard model.content != .bare else { return }
            ActivityTrail.mark("notch home band swiped away")
            dismissedBand = Self.bandKey(model.content, track: model.track, timer: NotchTimers.shared.running)
            refresh()
        case .restore:
            guard dismissedBand != nil else { return }
            ActivityTrail.mark("notch home band brought back")
            dismissedBand = nil
            NotchHome.tap()
            refresh()
        case .nextPage, .previousPage:
            turnPage(forward: swipe == .nextPage)
        case .nextPlayer, .previousPlayer:
            guard model.content == .expanded, model.page == .music, model.tracks.count > 1,
                let index = model.tracks.firstIndex(where: { $0.bundleID == model.track?.bundleID })
            else { return }
            let step = swipe == .nextPlayer ? 1 : -1
            let next = (index + step + model.tracks.count) % model.tracks.count
            selectPlayer(model.tracks[next].bundleID)
        case .none:
            break
        }
    }

    /// A click-drag reads like a swipe: toward the middle puts a band away; sideways on the open
    /// card turns the page; up and down there changes player.
    private func dragged(from startX: CGFloat, by translation: CGSize) {
        guard let panel, let model else { return }
        perform(
            Self.swipe(
                startX: startX, width: panel.frame.width, fingerDX: translation.width, fingerDY: translation.height,
                expanded: model.content == .expanded))
    }

    private func turnPage(forward: Bool) {
        guard let model, model.content == .expanded else { return }
        model.pagedForward = forward
        model.page = Self.page(after: model.page, forward: forward, hasTrack: model.track != nil)
    }

    private func selectPlayer(_ bundleID: String?) {
        selectedPlayer = bundleID
        model?.modes = nil
        refresh()
        if let track = model?.track { readModes(of: track) }
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
        pointerLeftAt = nil
        if !inside { shelfForDrag = false }
        if inside { NotchHome.tap() }
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

    /// While open: closes once the pointer leaves.
    private func checkPointer() {
        guard let panel, hovered else { return }
        // Opened by a drag, the card stays while the file is anywhere in the area that opened it:
        // the margin below the card counts, or the card would close under the file it is for.
        let area = (shelfForDrag ? dragZone() : nil) ?? panel.frame.insetBy(dx: -4, dy: -4)
        guard !area.contains(NSEvent.mouseLocation) else {
            pointerLeftAt = nil
            return
        }
        // A short grace, so brushing past the edge does not snap the card shut.
        let left = pointerLeftAt ?? Date()
        pointerLeftAt = left
        if Date().timeIntervalSince(left) >= NotchHome.leaveGrace { setHovered(false) }
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
                hasTrack: track != nil, timerRunning: timerRunning, dropping: dropping || shelfForDrag,
                meeting: meetingsWatched && NotchToday.shared.meeting != nil)
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
            onDropTargeted: { [weak self] targeted in self?.setDropTargeted(targeted) },
            onSelectTrack: { [weak self] bundleID in self?.selectPlayer(bundleID) },
            onPage: { [weak self] forward in self?.turnPage(forward: forward) },
            onDrag: { [weak self] startX, translation in self?.dragged(from: startX, by: translation) },
            onToggleMute: { NotchPrivacy.shared.toggleMute() },
            onJoin: { NotchToday.shared.join($0) })
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
