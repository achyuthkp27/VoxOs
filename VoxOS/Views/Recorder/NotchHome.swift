import AppKit
import Combine
import MediaRemoteAdapter
import QuartzCore
import SwiftUI
import UniformTypeIdentifiers
import VoxOSNowPlaying
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
    /// A volume or brightness icon, and its meter.
    static var levelWing: CGFloat { wing(holding: levelMeterWidth) }
    static let levelMeterWidth: CGFloat = 64
    /// A thin line, as macOS draws its own.
    static let levelMeterHeight: CGFloat = 3
    /// How far round the open card a dragged file opens the shelf.
    static let dragMargin: CGFloat = 24

    static func wing(holding content: CGFloat) -> CGFloat {
        NotchDesign.listening.shoulder + NotchDesign.contentInset + content + NotchDesign.contentInset
    }

    /// The open card: the same height on every page, so switching pages never moves the notch.
    /// The open card's coordinate space, in which drops and the AirDrop zone are measured.
    static let cardSpace = "NotchHome.card"

    enum Card {
        static let height: CGFloat = 132
        static let top: CGFloat = 8
        static let progressHeight: CGFloat = 14
        static let controlsHeight: CGFloat = 30
        static var bottom: CGFloat { AgentComposer.panelBottomInset }
        /// The cover tile: the card's height less its top and bottom insets.
        static var coverSize: CGFloat { height - top - bottom }

        /// The open card's height on a page: compact, except where a page has more to show. Fixed
        /// per page, never per reading, so a refresh cannot move the card's edge under the pointer.
        static func height(
            for page: NotchHomePage, panelOpen: Bool = false, mirrorShown: Bool = false,
            todayList: CGFloat = NotchTodayPage.minimumListHeight
        ) -> CGFloat {
            switch page {
            case .music: return panelOpen ? NotchMusicPanel.Layout.cardHeight : height
            case .weather: return NotchWeatherPage.cardHeight
            case .timer: return NotchTimerPage.cardHeight
            case .today: return NotchTodayPage.cardHeight(list: todayList)
            // The camera needs room to be seen: as tall as Weather while the mirror shows.
            case .sound: return mirrorShown ? NotchWeatherPage.cardHeight : height
            default: return height
            }
        }
    }

    struct Notice: Equatable {
        let symbol: String
        let title: String
        let detail: String?
    }

    enum Content: Equatable {
        case hidden
        /// Volume or brightness just changed with the keys, in place of macOS's pop-up.
        case level(NotchHUD.Level)
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
        /// A download in progress, and how many others are.
        case download(NotchDownloads.Item, others: Int)
        case expanded

        /// Shows something beyond the hardware notch.
        var isVisible: Bool { self != .hidden && self != .bare }
    }

    static var isEnabled: Bool {
        MasterSwitches.notchEnabled && UserDefaults.standard.bool(forKey: DefaultsKeys.notchHomeEnabled)
    }
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
    /// Left out of screenshots, recordings and screen sharing.
    static var hiddenFromCapture: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.notchHiddenFromCapture) }

    /// Collapsed, in order: a passing notice, the next meeting, a microphone or camera in use, a
    /// running timer, the playing track.
    static func content(
        enabled: Bool, hasNotch: Bool, blocked: Bool, hovered: Bool, dropping: Bool, notice: Notice?,
        timerRunning: Bool, musicPlaying: Bool, meeting: NotchToday.Event? = nil, privacy: NotchPrivacy.State? = nil,
        level: NotchHUD.Level? = nil, downloads: [NotchDownloads.Item] = []
    ) -> Content {
        guard enabled, hasNotch, !blocked else { return .hidden }
        if hovered || dropping { return .expanded }
        // The answer to a key just pressed comes before anything else.
        if let level { return .level(level) }
        if let notice { return .notice(notice) }
        if let meeting { return .meeting(meeting) }
        if let privacy, privacy.isActive { return .privacy(privacy) }
        if let download = downloads.first { return .download(download, others: downloads.count - 1) }
        if timerRunning { return .timer }
        if musicPlaying { return .playing }
        return .bare
    }

    static func size(
        for content: Content, notchWidth: CGFloat, notchHeight: CGFloat, cardHeight: CGFloat = Card.height
    ) -> CGSize {
        switch content {
        case .hidden, .bare:
            return CGSize(width: notchWidth, height: notchHeight)
        case .playing:
            return CGSize(width: notchWidth + wing * 2, height: notchHeight)
        case .timer:
            return CGSize(width: notchWidth + timerWing * 2, height: notchHeight)
        case .notice, .meeting, .download:
            return CGSize(width: notchWidth + noticeWing * 2, height: notchHeight)
        case .privacy:
            return CGSize(width: notchWidth + privacyWing * 2, height: notchHeight)
        case .level:
            return CGSize(width: notchWidth + levelWing * 2, height: notchHeight)
        case .expanded:
            return CGSize(
                width: max(NotchDesign.expandedWidth, notchWidth + wing * 2), height: notchHeight + cardHeight)
        }
    }

    static func radii(for content: Content) -> NotchDesign.Radii {
        switch content {
        case .hidden, .bare: return NotchDesign.resting
        case .playing, .timer, .notice, .meeting, .privacy, .level, .download: return NotchDesign.listening
        case .expanded: return NotchDesign.expanded
        }
    }

    static func frame(for size: CGSize, screenFrame: CGRect) -> CGRect {
        ClaudeCodeNotch.frame(for: size, screenFrame: screenFrame)
    }

    /// How long the notch is held to ask the Agent.
    static let askHold: TimeInterval = 0.5

    /// How long the pointer may be outside the open card before it closes.
    static let leaveGrace: TimeInterval = 0.22

    /// A light tap from the trackpad when the notch opens under the pointer or takes a drop: the
    /// "you arrived on something" pattern, timed to the frame that shows it. Nothing on a mouse.
    @MainActor
    static func tap(now: Date = Date()) {
        // Once per moment: hovering along the edge or a run of drops must not buzz.
        guard now.timeIntervalSince(lastTap) >= tapInterval else { return }
        lastTap = now
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
    }

    static let tapInterval: TimeInterval = 0.35
    @MainActor private static var lastTap = Date.distantPast

    /// Opens the card pinned, on the page named by the notification's object if any: from the menu
    /// bar's "Open Notch Home", and from scripts on this Mac (screenshots, automation). Distributed
    /// so a script can post it; all it can do is show the card.
    static let openRequest = Notification.Name("com.achyuthkp.voxos.notchHome.open")
    static let closeRequest = Notification.Name("com.achyuthkp.voxos.notchHome.close")

    /// How much of the queue Up Next lists.
    static let queueLength = 25

    /// Whether MediaRemote's queue belongs to `track`: its first item is the playing one, and
    /// MediaRemote answers for the player macOS calls current, which need not be the one shown.
    static func queue(startingWith first: String?, isFor track: NotchTrack) -> Bool {
        guard let first else { return false }
        return first.caseInsensitiveCompare(track.title) == .orderedSame
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
    /// Shown after the artist, "Artist — Album"; nil where the player did not say.
    var album: String? = nil

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
    /// The open card's height, for its page (`NotchHome.Card.height(for:)`).
    @Published var cardHeight: CGFloat = NotchHome.Card.height
    /// Apple Music's star for the track shown; nil where the player has none.
    @Published var favorite: Bool?
    /// The Music page's list (Up Next or Output) in place of the player; nil shows the player.
    @Published var musicPanel: NotchMusicPanel.Tab?
    /// The queue, playing track first, while Up Next is open; nil until it has been read.
    @Published var queue: [NowPlayingQueue.Item]?
    /// The track after the playing one, for "Up Next" in its last seconds.
    @Published var nextUp: NowPlayingQueue.Item?
    /// The format the playing track plays in, for the badge under the artist.
    @Published var audioFormat: NowPlayingQueue.AudioFormat?
    /// The Sound page shows the camera mirror, which takes a taller card.
    @Published var mirrorShown = false
    /// How tall the Calendar page's list is; the card fits it, up to a few rows.
    @Published var todayListHeight = NotchTodayPage.minimumListHeight
    /// While pages move: how far the current page is from its place, in points…
    @Published var pageOffset: CGFloat = 0
    /// …and the page shown beside it: the one coming in under the fingers, or the one sliding
    /// out once the swipe is let go.
    @Published var sidePage: NotchHomePage?
    /// The side page is to the right of the current one.
    @Published var sideOnRight = true
    /// Files are being dragged over the notch.
    @Published var dropping = false
    /// The bars follow the real output (see `NotchHome.liveBars`); otherwise they are ambient.
    @Published var liveBars = false
    /// Volume or brightness just changed; open, the card's top row shows it in place of the page.
    @Published var level: NotchHUD.Level?
    /// Pinned open: the card stays when the pointer leaves, until unpinned.
    @Published var pinned = false
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    /// No hardware notch on this display: the resting target is all but transparent instead of
    /// black, so nothing shows at the top of the screen until there is something to say.
    let virtualNotch: Bool

    init(notchWidth: CGFloat, notchHeight: CGFloat, virtualNotch: Bool = false) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.virtualNotch = virtualNotch
    }
}
