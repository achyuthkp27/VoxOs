import AppKit
import Combine
import MediaRemoteAdapter
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import VoxOSNowPlaying
import os

struct NotchHomeView: View {
    @ObservedObject var model: NotchHomeModel
    let onHover: (Bool) -> Void
    let onShuffle: () -> Void
    let onRepeat: () -> Void
    let onDropTargeted: (Bool) -> Void
    let onSelectTrack: (String?) -> Void
    /// Next page (true) or previous (false).
    let onPage: (Bool) -> Void
    /// A click-drag moved this far.
    let onDragChanged: (CGSize) -> Void
    /// A click-drag ended: where it started (window x), how far it went, and how far it would
    /// have gone with its speed.
    let onDrag: (CGFloat, CGSize, CGSize) -> Void
    let onToggleMute: () -> Void
    let onJoin: (NotchToday.Event) -> Void
    let onPin: () -> Void
    @ObservedObject var lyrics = NotchLyrics.shared
    @AppStorage(DefaultsKeys.notchMusicBarsEnabled) private var barsEnabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var content: NotchHome.Content { model.content }
    private var size: CGSize {
        NotchHome.size(
            for: content, notchWidth: model.notchWidth, notchHeight: model.notchHeight, cardHeight: model.cardHeight)
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
                    pages
                        .frame(height: model.cardHeight, alignment: .top)
                        // Opening brings the page into focus where it is; only a swipe moves
                        // pages sideways.
                        .transition(reduceMotion ? .opacity : .blurIn)
                }
            }
            if content == .expanded, model.page == .music, model.sidePage == nil, model.musicPanel == nil,
                model.tracks.count > 1
            {
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
                .onChanged { value in onDragChanged(value.translation) }
                .onEnded { value in onDrag(value.startLocation.x, value.translation, value.predictedEndTranslation) }
        )
        .coordinateSpace(name: NotchHome.cardSpace)
        .onDrop(of: [.fileURL], delegate: NotchCardDropDelegate(onTargeted: onDropTargeted))
        .animation(
            reduceMotion ? nil : (content == .expanded ? NotchDesign.openAnimation : NotchDesign.closeAnimation),
            value: content
        )
        .animation(reduceMotion ? nil : NotchDesign.openAnimation, value: model.cardHeight)
    }

    /// The current page and, while pages move, the one beside it, moving together like sheets
    /// under the fingers. Identity follows the page, so the one sliding in stays the same view
    /// once it is the current one.
    private var pages: some View {
        ZStack(alignment: .topLeading) {
            ForEach([model.page] + (model.sidePage.map { [$0] } ?? []), id: \.self) { page in
                pageView(page)
                    .frame(width: size.width, height: model.cardHeight, alignment: .top)
                    .offset(x: offset(of: page))
            }
        }
        .frame(width: size.width, height: model.cardHeight, alignment: .topLeading)
        .clipped()
    }

    private func offset(of page: NotchHomePage) -> CGFloat {
        guard page != model.page else { return model.pageOffset }
        return model.pageOffset + (model.sideOnRight ? size.width : -size.width)
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

    /// The star: flipped at once, then set in Music and read back, which has the last word (and
    /// puts it back if Music would not change it).
    private func toggleFavorite(_ track: NotchTrack) {
        let wanted = !(model.favorite ?? false)
        model.favorite = wanted
        Task { @MainActor [weak model] in
            let answer = await NotchPlaybackModes.setFavorite(track.bundleID, to: wanted)
            guard model?.track?.id == track.id else { return }
            model?.favorite = answer ?? !wanted
        }
    }

    /// Plays a track from Up Next, then reads the queue again once the player has moved on.
    private func playQueued(_ offset: Int, _ item: NowPlayingQueue.Item) {
        Task { @MainActor [weak model] in
            await NowPlayingQueue.play(offset: offset, id: item.id)
            try? await Task.sleep(for: .milliseconds(600))
            model?.queue = await NowPlayingQueue.read(length: NotchHome.queueLength)
        }
    }

    @ViewBuilder
    private func pageView(_ page: NotchHomePage) -> some View {
        switch page {
        case .music:
            if let tab = model.musicPanel {
                NotchMusicPanel(
                    tab: tab, queue: model.queue, rate: model.track?.rate ?? 1, onTab: { model.musicPanel = $0 },
                    onPlay: { offset, item in playQueued(offset, item) }, onClose: { model.musicPanel = nil })
            } else if let track = model.track {
                NotchHomePlayer(
                    track: track, modes: model.modes, favorite: model.favorite, format: model.audioFormat,
                    next: model.nextUp, liveBars: model.liveBars, lyrics: lyrics.lines, onShuffle: onShuffle,
                    onRepeat: onRepeat, onFavorite: { toggleFavorite(track) }, onList: { model.musicPanel = .upNext },
                    onToggleBars: { barsEnabled.toggle() })
            }
        case .timer:
            NotchTimerPage(timers: .shared)
        case .today:
            NotchTodayPage(today: .shared, reminders: .shared, onListHeight: { model.todayListHeight = $0 })
        case .weather:
            NotchWeatherPage(today: .shared)
        case .shelf:
            NotchShelfPage(
                shelf: .shared, dropping: model.dropping, pinned: model.pinned, onPin: onPin)
        case .sound:
            NotchSoundPage(
                mixer: .shared, clipboard: .shared, mirror: .shared, keepAwake: .shared, pinned: model.pinned,
                onPin: onPin, onMirrorShown: { model.mirrorShown = $0 })
        }
    }

    /// One thing in each wing. Open, the left wing names the page (behind the cover on Music)
    /// and the right one switches pages. Held down, the notch asks the Agent, as ⌃⌃ does.
    private var notchRow: some View {
        HStack(spacing: 0) {
            leftWing
            Spacer(minLength: 0)
            rightWing
        }
        .padding(.horizontal, inset)
        .frame(width: size.width, height: model.notchHeight)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: NotchHome.askHold) {
            NotchHome.tap()
            NotificationCenter.default.post(name: RecordingShortcutManager.askAgentFromNotch, object: nil)
        }
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
        case .download(let item, _):
            HStack(spacing: 7) {
                Image(systemName: "arrow.down.circle.fill").font(.system(size: 12, weight: .semibold))
                Text(verbatim: item.name).font(.app(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: NotchHome.noticeWing - inset - NotchDesign.contentInset, alignment: .leading)
        case .level(let level):
            Image(systemName: level.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, alignment: .leading)
                .contentTransition(.symbolEffect(.replace))
        case .expanded where model.level != nil:
            if let level = model.level { NotchLevelReadout(level: level) }
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
        case .download(let item, let others):
            HStack(spacing: 6) {
                if others > 0 {
                    Text(verbatim: "+\(others)")
                        .font(.appMono(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Text(verbatim: "\(Int((item.fraction * 100).rounded(.down)))%")
                    .font(.appMono(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .monospacedDigit()
            }
        case .level(let level):
            NotchLevelMeter(value: level.muted ? 0 : level.value)
                .frame(width: NotchHome.levelMeterWidth, height: NotchHome.levelMeterHeight)
                .accessibilityLabel(Text(level.kind == .volume ? "Volume" : "Brightness"))
                .accessibilityValue(Text("\(Int((level.muted ? 0 : level.value) * 100)) percent"))
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

    /// Solid Black: one black surface, opaque while open, so a document's text never shows
    /// through. Liquid Glass: the open card is glass below the notch row, the black fading into it.
    @AppStorage(DefaultsKeys.notchMaterial) private var materialRaw = NotchDesign.Material.liquidGlass.rawValue

    @ViewBuilder
    private var background: some View {
        if content == .expanded, NotchDesign.Material.resolve(materialRaw) == .liquidGlass {
            NotchGlassSurface(shape: shape, solidHeight: model.notchHeight, totalHeight: size.height)
        } else {
            solidBackground
        }
    }

    private var solidBackground: some View {
        shape.fill(
            content == .expanded
                ? Color(red: 0, green: 0, blue: 2 / 255)
                // Faint enough to see through, opaque enough to be hovered and dropped on.
                : (model.virtualNotch && !content.isVisible ? Color.black.opacity(0.012) : NotchDesign.solid))
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

extension AnyTransition {
    /// In from a soft blur, as the card opens; out the same way.
    static var blurIn: AnyTransition {
        .modifier(active: NotchBlur(radius: 6, opacity: 0), identity: NotchBlur(radius: 0, opacity: 1))
    }
}

private struct NotchBlur: ViewModifier {
    let radius: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(opacity)
    }
}

/// A slim meter for volume or brightness, filling from the left.
struct NotchLevelMeter: View {
    let value: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(.white).frame(width: max(0, geo.size.width * CGFloat(min(1, max(0, value)))))
            }
        }
        .animation(.easeOut(duration: 0.12), value: value)
    }
}

/// The level in the open card's top row, while a key is pressed with the card open.
private struct NotchLevelReadout: View {
    let level: NotchHUD.Level

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: level.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 18, alignment: .leading)
            NotchLevelMeter(value: level.muted ? 0 : level.value)
                .frame(width: NotchHome.levelMeterWidth, height: NotchHome.levelMeterHeight)
        }
    }
}

/// "Join", on the meeting band and beside a meeting on the Calendar page.
/// Files dragged onto the open card: onto the Shelf page's AirDrop zone they go by AirDrop;
/// anywhere else they are kept on the shelf.
@MainActor
struct NotchCardDropDelegate: DropDelegate {
    let onTargeted: (Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }

    func dropEntered(info: DropInfo) {
        onTargeted(true)
        track(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        track(info)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        NotchShelf.shared.airDropTargeted = false
        onTargeted(false)
    }

    func performDrop(info: DropInfo) -> Bool {
        let shelf = NotchShelf.shared
        let toAirDrop = Self.isOverAirDrop(info.location, zone: shelf.airDropZone)
        shelf.airDropTargeted = false
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else {
            onTargeted(false)
            return false
        }
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.url(from: provider) { urls.append(url) }
            }
            // AirDrop first: its picker keeps the card open once the drag has left it.
            if toAirDrop { shelf.airDrop(urls) } else { shelf.add(urls) }
            if !urls.isEmpty { NotchHome.tap() }
            onTargeted(false)
        }
        return true
    }

    private func track(_ info: DropInfo) {
        let over = Self.isOverAirDrop(info.location, zone: NotchShelf.shared.airDropZone)
        if NotchShelf.shared.airDropTargeted != over { NotchShelf.shared.airDropTargeted = over }
    }

    nonisolated static func isOverAirDrop(_ point: CGPoint, zone: CGRect?) -> Bool {
        zone?.contains(point) ?? false
    }

    nonisolated static func url(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
}

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
