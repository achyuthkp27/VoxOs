import AppKit
import Combine
import MediaRemoteAdapter
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import VoxOSNowPlaying
import os

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
    /// A two-finger swipe in progress: where it started, how far the fingers have moved, the
    /// last step (its speed), and the axis it locked to once it moved enough to tell.
    private struct ScrollGesture {
        let startX: CGFloat
        let width: CGFloat
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        var lastDX: CGFloat = 0
        var horizontal: Bool?
    }
    private var gesture: ScrollGesture?
    /// The page a slide is landing on, until it has.
    private var landing: NotchHomePage?
    private var cancellables: Set<AnyCancellable> = []
    private var resizeTask: Task<Void, Never>?
    private var pointerWatch: Timer?
    private var artworkCache: (key: String, image: NSImage?, tint: Color)?
    /// The tint of each player's cover, so a refresh does not draw the cover again to find it.
    private var tintCache: [String: Color] = [:]
    /// Whether the front app fills the screen, until the front app, the Space or the screen
    /// changes (a full-screen window has a Space of its own), so a refresh does not read the
    /// window list each time.
    private var fullScreenCache: (pid: pid_t?, screen: CGRect, value: Bool, at: Date)?
    private var refreshScheduled = false
    /// Files dragged in another app, seen through a global mouse monitor (see `globalMouse`).
    private var dragMonitor: Any?
    private var dragChangeCount = 0
    /// A dragged file reached the notch's area and opened the card on the shelf.
    private var shelfForDrag = false
    private var meetingsWatched = false
    private var mixerWasOn = false
    private var meetingWatch: AnyCancellable?
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "NotchHome")

    init(uiManager: RecorderUIManager) {
        self.uiManager = uiManager
        PlaybackController.shared.$nowPlaying.receive(on: RunLoop.main).sink { [weak self] _ in self?.setNeedsRefresh()
        }
        .store(in: &cancellables)
        uiManager.$isRecorderPanelVisible.receive(on: RunLoop.main).sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
        uiManager.$isClaudeCodeCardVisible.receive(on: RunLoop.main).sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
        NotchTimers.shared.$running.receive(on: RunLoop.main).sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
        NotchTimers.shared.$finished.receive(on: RunLoop.main).sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
        NotchDeviceAlerts.shared.$notice.receive(on: RunLoop.main).sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
        NotchPlayers.shared.$entries.receive(on: RunLoop.main).sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
        NotchPrivacy.shared.$state.receive(on: RunLoop.main).sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
        NotchHUD.shared.$level.receive(on: RunLoop.main).sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
        NotchDownloads.shared.$active.receive(on: RunLoop.main).sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
        NotchDownloads.shared.$finished.receive(on: RunLoop.main).sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
        NotchFocus.shared.$notice.receive(on: RunLoop.main).sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
        AppSwitcher.shared.$notice.receive(on: RunLoop.main).sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
        ClaudeCodeUsage.shared.$notice.receive(on: RunLoop.main).sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
        CodexActivity.shared.$notice.receive(on: RunLoop.main).sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
        GeminiActivity.shared.$notice.receive(on: RunLoop.main).sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
        ClaudeCodeCIWatch.shared.$notice.receive(on: RunLoop.main).sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
        NotchRainWatch.shared.$notice.receive(on: RunLoop.main).sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
        NotchUnread.shared.$notice.receive(on: RunLoop.main).sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
        // Entering or leaving a full-screen app is a Space change.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.fullScreenCache = nil
                self?.setNeedsRefresh()
            }
            .store(in: &cancellables)
        // Another app in front brings other menus, which may reach further toward the notch.
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.clearanceMeasured = nil
                self?.fullScreenCache = nil
                self?.setNeedsRefresh()
            }
            .store(in: &cancellables)
        let distributed = DistributedNotificationCenter.default()
        distributed.publisher(for: NotchHome.openRequest).receive(on: RunLoop.main)
            .sink { [weak self] note in
                self?.openPinned(on: (note.object as? String).flatMap(NotchHomePage.init(rawValue:)))
            }
            .store(in: &cancellables)
        distributed.publisher(for: NotchHome.closeRequest).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.closePinned() }
            .store(in: &cancellables)
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if let self, let panel = self.panel, event.window === panel { self.handleScroll(event, in: panel) }
            return event
        }
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.setNeedsRefresh() }
            .store(in: &cancellables)
        // Battery, Low Power Mode, displays asleep or the screen locked.
        PowerState.shared.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in self?.setNeedsRefresh() }
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

    /// Many sources change together (a new track touches MediaRemote and the player at once, a
    /// download reports twice a second), so their sinks ask for one refresh on the next turn of
    /// the run loop instead of one each.
    private func setNeedsRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refresh()
            }
        }
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
        if enabled && NotchDownloads.isEnabled { NotchDownloads.shared.start() } else { NotchDownloads.shared.stop() }
        if enabled && NotchFocus.isEnabled { NotchFocus.shared.start() } else { NotchFocus.shared.stop() }
        if enabled && NotchClipboard.isEnabled { NotchClipboard.shared.start() } else { NotchClipboard.shared.stop() }
        NotchRainWatch.shared.setActive(enabled && NotchRainWatch.isEnabled && NotchRainWatch.locationAllowed)
        if enabled && NotchUnread.isEnabled { NotchUnread.shared.start() } else { NotchUnread.shared.stop() }
        // Switched off: every app back to full, which also ends its tap.
        if !(enabled && NotchMixer.isEnabled), mixerWasOn { NotchMixer.shared.reset() }
        mixerWasOn = enabled && NotchMixer.isEnabled
        let meeting = watchMeetings(enabled && NotchHome.meetingsEnabled && NotchToday.accessGranted)
        watchDrags(enabled)

        let tracks = wantsMusic ? makeTracks() : []
        // Another display now (one attached or closed, or the display in use changed): the panel
        // is built again there.
        let target = NotchScreens.target()
        if let current = self.screen, target != nil, !NotchScreens.same(current, target) { destroyPanel() }
        let screen = self.screen ?? target
        let hiddenForFullScreen =
            !NotchHome.showsInFullScreen && screen.map(frontAppFillsScreen(on:)) == true
        let track = Self.shown(tracks, selected: selectedPlayer)
        let timers = NotchTimers.shared
        var content = NotchHome.content(
            enabled: enabled && !hiddenForFullScreen, hasNotch: screen != nil,
            blocked: uiManager.isRecorderPanelVisible || uiManager.isClaudeCodeCardVisible, hovered: hovered,
            dropping: dropping,
            notice: AppSwitcher.shared.notice
                ?? Self.notice(device: NotchDeviceAlerts.shared.notice, finished: timers.finished)
                ?? NotchFocus.shared.notice ?? ClaudeCodeUsage.shared.notice ?? GeminiActivity.shared.notice
                ?? CodexActivity.shared.notice
                ?? ClaudeCodeCIWatch.shared.notice ?? NotchRainWatch.shared.notice ?? NotchUnread.shared.notice
                ?? Self.downloadNotice(NotchDownloads.shared.finished),
            timerRunning: timers.running != nil, musicPlaying: track?.isPlaying == true, meeting: meeting,
            privacy: NotchPrivacy.shared.state, level: NotchHUD.shared.level,
            downloads: NotchDownloads.shared.active)
        // The keys are taken from macOS only while the notch can answer them.
        NotchHUD.shared.update(canShow: content != .hidden)
        if model?.level != NotchHUD.shared.level { model?.level = NotchHUD.shared.level }
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
        // The sung line is looked up only while the Music page is open with lyrics switched on.
        if NotchLyrics.isEnabled, content == .expanded, model?.page == .music, let track {
            NotchLyrics.shared.load(title: track.title, artist: track.artist, duration: track.duration)
        } else if !NotchLyrics.isEnabled {
            NotchLyrics.shared.clear()
        }
        let sharing: NSWindow.SharingType = NotchHome.hiddenFromCapture ? .none : .readOnly
        if let panel, panel.sharingType != sharing { panel.sharingType = sharing }
    }

    /// The meeting countdown runs only while wanted and the calendar may be read; the calendar is
    /// not touched otherwise, so nothing asks for access from here.
    private func watchMeetings(_ wanted: Bool) -> NotchToday.Event? {
        if wanted != meetingsWatched {
            meetingsWatched = wanted
            if wanted, meetingWatch == nil {
                meetingWatch = NotchToday.shared.$meeting.dropFirst().receive(on: RunLoop.main)
                    .sink { [weak self] _ in self?.setNeedsRefresh() }
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
        let size = NotchHome.size(
            for: .expanded, notchWidth: model.notchWidth, notchHeight: model.notchHeight, cardHeight: model.cardHeight)
        return NotchHome.frame(for: size, screenFrame: screen.frame)
            .insetBy(dx: -NotchHome.dragMargin, dy: -NotchHome.dragMargin)
    }

    /// `frontAppIsFullScreen`, read again only when the front app or the screen changed, a Space
    /// changed, or a few seconds passed.
    private func frontAppFillsScreen(on screen: NSScreen) -> Bool {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let cache = fullScreenCache, cache.pid == pid, cache.screen == screen.frame,
            Date().timeIntervalSince(cache.at) < 5
        {
            return cache.value
        }
        let value = Self.frontAppIsFullScreen(on: screen)
        fullScreenCache = (pid, screen.frame, value, Date())
        return value
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
        clearanceRequest += 1
        let request = clearanceRequest
        Task { @MainActor [weak self] in
            let measured = await NotchMenuBarClearance.measure(notchMinX: notchMinX, notchMaxX: notchMaxX, front: front)
            guard let self, request == self.clearanceRequest, measured.wing != self.allowedWing else { return }
            self.allowedWing = measured.wing
            self.logger.notice(
                "Notch home: room beside the notch \(measured.wing.map { String(Int($0)) } ?? "unknown", privacy: .public) pt, limited by \(measured.limitedBy, privacy: .public)"
            )
            self.refresh()
        }
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
                    rate: entry.isPlaying ? 1 : 0, artwork: entry.artwork, tint: tint(of: entry),
                    bundleID: entry.bundleID, album: entry.album))
        }
        return tracks.sorted { ($0.bundleID ?? "") < ($1.bundleID ?? "") }
    }

    /// Drawn once per cover: a player's entry keeps its image until the track changes.
    private func tint(of entry: NotchPlayers.Entry) -> Color {
        let key = entry.trackKey + "|" + (entry.artworkKey ?? entry.artwork.map { "\(ObjectIdentifier($0))" } ?? "")
        if let tint = tintCache[key] { return tint }
        let tint = Self.tint(of: entry.artwork)
        if tintCache.count >= 8 { tintCache.removeAll() }
        tintCache[key] = tint
        return tint
    }

    /// Sideways on the open card, the page follows the fingers and the next one comes in beside
    /// it; up and down changes player once let go. Momentum after the fingers lift is ignored.
    private func handleScroll(_ event: NSEvent, in panel: NSPanel) {
        // Natural scrolling flips the deltas; turned back here, they follow the fingers.
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        let expanded = model?.content == .expanded
        switch event.phase {
        case .began:
            land()
            gesture = ScrollGesture(startX: event.locationInWindow.x, width: panel.frame.width)
        case .changed:
            guard var moved = gesture else { return }
            let step = event.scrollingDeltaX * sign
            moved.dx += step
            moved.dy += event.scrollingDeltaY * sign
            moved.lastDX = step
            if moved.horizontal == nil, max(abs(moved.dx), abs(moved.dy)) >= Self.axisLock {
                moved.horizontal = abs(moved.dx) > abs(moved.dy)
            }
            gesture = moved
            if expanded, moved.horizontal == true { movePage(by: moved.dx) }
        case .ended, .cancelled:
            guard let moved = gesture else { return }
            gesture = nil
            if expanded, moved.horizontal == true {
                finishPage(dx: event.phase == .cancelled ? 0 : moved.dx, flick: moved.lastDX)
            } else if moved.horizontal != nil {
                // Open, a swipe that locked up-and-down changes player and never the page;
                // collapsed, the whole movement decides.
                perform(
                    Self.swipe(
                        startX: moved.startX, width: moved.width, fingerDX: expanded ? 0 : moved.dx,
                        fingerDY: moved.dy, expanded: expanded))
            }
        default:
            break
        }
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private static func withoutAnimation(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    /// The page under the fingers, and the one it is moving toward beside it.
    private func movePage(by dx: CGFloat) {
        guard let model, let panel, model.content == .expanded, !reduceMotion else { return }
        let width = panel.frame.width
        let forward = dx < 0
        let incoming = Self.page(after: model.page, forward: forward, hasTrack: model.track != nil)
        guard incoming != model.page else { return }
        Self.withoutAnimation {
            if model.sideOnRight != forward { model.sideOnRight = forward }
            if model.sidePage != incoming { model.sidePage = incoming }
            model.pageOffset = max(-width, min(width, dx))
        }
    }

    private func finishPage(dx: CGFloat, flick: CGFloat) {
        guard let model, let panel else { return }
        guard model.sidePage != nil else {
            // Reduce Motion: nothing followed the fingers, but a swipe still turns the page.
            if reduceMotion, abs(dx) >= Self.pageSwipe { slide(forward: dx < 0) }
            return
        }
        if Self.commitsPage(dx: dx, flick: flick, width: panel.frame.width) {
            slide(forward: dx < 0)
        } else {
            ActivityTrail.mark("notch home page settled back")
            withAnimation(NotchDesign.pageAnimation, completionCriteria: .logicallyComplete) {
                model.pageOffset = 0
            } completion: { [weak model] in
                guard let model, model.pageOffset == 0 else { return }
                Self.withoutAnimation { model.sidePage = nil }
            }
        }
    }

    /// The incoming page becomes the current one where it stands, and both slide the rest of the
    /// way; a click on the page button starts the same slide from rest.
    private func slide(forward: Bool) {
        guard let model, let panel, model.content == .expanded else { return }
        let width = panel.frame.width
        let incoming = Self.page(after: model.page, forward: forward, hasTrack: model.track != nil)
        guard incoming != model.page else { return }
        ActivityTrail.mark("notch home page \(incoming.rawValue)")
        if reduceMotion {
            Self.withoutAnimation {
                model.page = incoming
                model.sidePage = nil
                model.pageOffset = 0
            }
            return
        }
        let outgoing = model.page
        // Where the incoming page stands now: beside the current one, wherever the fingers left it.
        let start = (model.sidePage == incoming ? model.pageOffset : 0) + (forward ? width : -width)
        Self.withoutAnimation {
            model.page = incoming
            model.sidePage = outgoing
            model.sideOnRight = !forward
            model.pageOffset = start
        }
        landing = incoming
        // The next pass, so the new arrangement is drawn before it moves.
        DispatchQueue.main.async { [weak self, weak model] in
            guard let model, self?.landing == incoming else { return }
            withAnimation(NotchDesign.pageAnimation, completionCriteria: .logicallyComplete) {
                model.pageOffset = 0
            } completion: { [weak self] in
                guard self?.landing == incoming else { return }
                self?.land()
            }
        }
    }

    /// Ends a slide at once, as a new swipe starts: the page it was going to is simply there.
    private func land() {
        landing = nil
        guard let model, model.sidePage != nil || model.pageOffset != 0 else { return }
        Self.withoutAnimation {
            model.sidePage = nil
            model.pageOffset = 0
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

    /// A click-drag reads like a swipe: sideways on the open card the page follows the pointer;
    /// not on the shelf, where dragging a file out must not move the page.
    private func dragChanged(by translation: CGSize) {
        guard let model, model.content == .expanded, model.page != .shelf,
            abs(translation.width) > abs(translation.height)
        else { return }
        // A slide still landing is finished first, so the drag starts from a page at rest.
        if landing != nil { land() }
        movePage(by: translation.width)
    }

    /// Ended: a page in motion goes or settles; otherwise it is a swipe, toward the middle
    /// putting a band away, up and down on the open card changing player.
    private func dragged(from startX: CGFloat, by translation: CGSize, predicted: CGSize) {
        guard let panel, let model else { return }
        if model.content == .expanded, landing == nil, model.sidePage != nil || reduceMotion,
            model.page != .shelf, abs(translation.width) > abs(translation.height)
        {
            return finishPage(dx: translation.width, flick: (predicted.width - translation.width) / 8)
        }
        let swipe = Self.swipe(
            startX: startX, width: panel.frame.width, fingerDX: translation.width, fingerDY: translation.height,
            expanded: model.content == .expanded)
        // Pages move only under the pointer, above; the shelf keeps its drags for files.
        if swipe == .nextPage || swipe == .previousPage { return }
        perform(swipe)
    }

    /// Open without the pointer, pinned so it stays until unpinned or closed.
    private func openPinned(on page: NotchHomePage?) {
        ActivityTrail.mark("notch home opened by request")
        setHovered(true)
        guard let model, model.content == .expanded else { return }
        model.pinned = true
        if let page, NotchHomePage.available(hasTrack: model.track != nil).contains(page) {
            land()
            model.page = page
        }
    }

    private func closePinned() {
        guard hovered else { return }
        model?.pinned = false
        setHovered(false)
    }

    private func togglePin() {
        guard let model else { return }
        model.pinned.toggle()
        ActivityTrail.mark("notch home \(model.pinned ? "pinned" : "unpinned")")
    }

    private func turnPage(forward: Bool) {
        land()
        slide(forward: forward)
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
            tint: artworkCache?.tint ?? .white, bundleID: payload.bundleIdentifier, album: payload.album)
    }

    // MARK: Hover

    private func setHovered(_ inside: Bool) {
        guard inside != hovered else { return }
        hovered = inside
        ActivityTrail.mark("notch home hover \(inside)")
        pointerLeftAt = nil
        if !inside {
            shelfForDrag = false
            model?.pinned = false
        }
        if inside { NotchHome.tap() }
        if inside {
            // mouseExited is not reliable on a panel that resizes under the pointer, so while
            // open the pointer itself is checked.
            pointerWatch?.invalidate()
            let watch = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkPointer() }
            }
            // Slack lets macOS fold these checks into other wake-ups.
            watch.tolerance = 0.03
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
        // Pinned, or an AirDrop or share sheet from the card is up: the card waits for it.
        if model?.pinned == true || NotchShelf.shared.isSharing {
            pointerLeftAt = nil
            return
        }
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
        if model.track != track {
            let changed = model.track?.id != track?.id
            model.track = track
            // A new track while the card is open: its star, format and what follows are re-read.
            if changed, model.content == .expanded { readModes(of: track) }
        }
        if content == .expanded, model.content != .expanded {
            land()
            model.page = NotchHomePage.preferred(
                hasTrack: track != nil, timerRunning: timerRunning, dropping: dropping || shelfForDrag,
                meeting: meetingsWatched && NotchToday.shared.meeting != nil)
            readModes(of: track)
        }
        // A page that went away (no track, or switched off in Settings) gives way to the first
        // one that is on, in the user's order, rather than always to the day.
        let available = NotchHomePage.available(hasTrack: track != nil)
        if !available.contains(model.page) { model.page = available.first ?? .today }
        if panel.isVisible, model.content == content { return }
        resizeTask?.cancel()

        // Opening: the card at its page's height from the first frame.
        if content == .expanded {
            model.musicPanel = nil
            model.mirrorShown = false
            model.cardHeight = NotchHome.Card.height(for: model.page, todayList: model.todayListHeight)
        }
        let target = NotchHome.size(
            for: content, notchWidth: model.notchWidth, notchHeight: model.notchHeight, cardHeight: model.cardHeight)
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
        readQueueHead(of: track)
        if model?.musicPanel == .upNext { readQueue() }
        model?.favorite = nil
        if NotchPlaybackModes.canFavorite(track?.bundleID) {
            Task { @MainActor [weak model] in
                let favorite = await NotchPlaybackModes.readFavorite(track?.bundleID)
                guard model?.track?.id == track?.id else { return }
                model?.favorite = favorite
            }
        }
        guard NotchPlaybackModes.canReadState(of: track?.bundleID) else { return }
        Task { @MainActor [weak model] in
            let state = await NotchPlaybackModes.read(track?.bundleID)
            model?.modes = state
        }
    }

    private func buildPanel(on screen: NSScreen) {
        guard let metrics = NotchRecorderPanel.calculateWindowMetrics(on: screen) else { return }
        self.screen = screen
        let model = NotchHomeModel(
            notchWidth: metrics.notchWidth, notchHeight: metrics.notchHeight,
            virtualNotch: !NotchScreens.hasNotch(screen))
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
            onDragChanged: { [weak self] translation in self?.dragChanged(by: translation) },
            onDrag: { [weak self] startX, translation, predicted in
                self?.dragged(from: startX, by: translation, predicted: predicted)
            },
            onToggleMute: { NotchPrivacy.shared.toggleMute() },
            onJoin: { NotchToday.shared.join($0) },
            onPin: { [weak self] in self?.togglePin() })
        panel.contentView = NotchRecorderHostingController(rootView: view).view
        panel.sharingType = NotchHome.hiddenFromCapture ? .none : .readOnly
        self.model = model
        self.panel = panel
        // The live bars depend on the page, so a page switch is a refresh; and the card takes the
        // new page's height.
        model.$page.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in
            self?.fitCard()
            self?.setNeedsRefresh()
        }
        .store(in: &cancellables)
        // Showing or leaving the camera mirror changes the Sound page's height.
        model.$mirrorShown.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.fitCard() }
            .store(in: &cancellables)
        // The Calendar page's list growing or shrinking changes its height.
        model.$todayListHeight.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.fitCard() }
            .store(in: &cancellables)
        // Opening or closing the Music page's list changes its height; Up Next reads the queue.
        model.$musicPanel.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] tab in
                self?.fitCard()
                if tab == .upNext { self?.readQueue() }
            }
            .store(in: &cancellables)
        logger.notice("Notch home built")
    }

    /// The playing track's format and the one after it, from MediaRemote's queue: one short read
    /// when the card opens or the track changes.
    private func readQueueHead(of track: NotchTrack?) {
        model?.audioFormat = nil
        model?.nextUp = nil
        guard track != nil else { return }
        Task { @MainActor [weak model] in
            let items = await NowPlayingQueue.read(length: 2)
            guard model?.track?.id == track?.id, let track, let items,
                NotchHome.queue(startingWith: items.first?.title, isFor: track)
            else { return }
            model?.audioFormat = items.first?.format
            model?.nextUp = items.count > 1 ? items[1] : nil
        }
    }

    /// Up Next's list: read when it opens, and when the track changes while it is open.
    private func readQueue() {
        guard let model else { return }
        model.queue = nil
        let track = model.track
        Task { @MainActor [weak model] in
            let items = await NowPlayingQueue.read(length: NotchHome.queueLength)
            guard model?.track?.id == track?.id else { return }
            // MediaRemote's queue is the player macOS calls current; another player shown here has
            // none to list.
            if let track, let items, NotchHome.queue(startingWith: items.first?.title, isFor: track) {
                model?.queue = items
            } else {
                model?.queue = []
            }
        }
    }

    /// The open card follows its page's height. Growing, the window grows first and the card with it;
    /// shrinking, the card shrinks first and the window after, so the card is never cut off.
    private func fitCard() {
        guard let model, let panel, let screen else { return }
        let height = NotchHome.Card.height(
            for: model.page, panelOpen: model.musicPanel != nil, mirrorShown: model.mirrorShown,
            todayList: model.todayListHeight)
        guard height != model.cardHeight else { return }
        guard model.content == .expanded, panel.isVisible else {
            model.cardHeight = height
            return
        }
        resizeTask?.cancel()
        let target = NotchHome.size(
            for: .expanded, notchWidth: model.notchWidth, notchHeight: model.notchHeight, cardHeight: height)
        if height > model.cardHeight {
            panel.setFrame(NotchHome.frame(for: target, screenFrame: screen.frame), display: true)
            model.cardHeight = height
        } else {
            model.cardHeight = height
            resizeTask = Task { @MainActor [weak panel, weak self] in
                try? await Task.sleep(for: .seconds(NotchDesign.closeDuration + 0.1))
                guard !Task.isCancelled, let panel, let screen = self?.screen else { return }
                panel.setFrame(NotchHome.frame(for: target, screenFrame: screen.frame), display: true)
            }
        }
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
        // The menu bar beside another display's notch is measured afresh.
        allowedWing = nil
        clearanceMeasured = nil
    }
}
