import AppKit
import Foundation
import Testing

@testable import VoxOS

/// The notch's music. The bars must follow the sound that is really playing, which is why the
/// analyzer is tested with tones: a fake animation would pass any test that only checks motion.
@Suite
@MainActor
struct NotchHomeTests {

    // MARK: Analyzer

    private static func tone(_ frequency: Float, seconds: Float = 0.2, amplitude: Float = 0.5, rate: Float = 48_000)
        -> [Float]
    {
        (0..<Int(rate * seconds)).map { amplitude * sin(2 * .pi * frequency * Float($0) / rate) }
    }

    @Test func aBassToneLightsTheBassBarOnly() {
        var analyzer = SpectrumAnalyzer(sampleRate: 48_000)
        analyzer.feed(Self.tone(100))
        let levels = analyzer.levels
        #expect(levels[0] > 0.6, "bass bar \(levels)")
        #expect(levels[3] < levels[0] * 0.5, "presence stays low \(levels)")
        #expect(levels[4] < levels[0] * 0.5, "air stays low \(levels)")
    }

    @Test func aHighToneLightsAHighBar() {
        var analyzer = SpectrumAnalyzer(sampleRate: 48_000)
        analyzer.feed(Self.tone(3_000))
        let levels = analyzer.levels
        #expect(levels[3] > 0.6, "presence bar \(levels)")
        #expect(levels[0] < levels[3] * 0.5, "bass stays low \(levels)")
    }

    @Test func silenceLetsTheBarsFall() {
        var analyzer = SpectrumAnalyzer(sampleRate: 48_000)
        analyzer.feed(Self.tone(100))
        let loud = analyzer.levels[0]
        analyzer.feed([Float](repeating: 0, count: 48_000 / 4))
        #expect(analyzer.levels[0] < loud * 0.2, "fell from \(loud) to \(analyzer.levels[0])")
    }

    @Test func louderIsTaller() {
        var quiet = SpectrumAnalyzer(sampleRate: 48_000)
        var loud = SpectrumAnalyzer(sampleRate: 48_000)
        quiet.feed(Self.tone(400, amplitude: 0.02))
        loud.feed(Self.tone(400, amplitude: 0.5))
        #expect(loud.levels[1] > quiet.levels[1])
    }

    // MARK: What the notch shows

    private func content(
        enabled: Bool = true, hasNotch: Bool = true, blocked: Bool = false, hovered: Bool = false,
        dropping: Bool = false, notice: NotchHome.Notice? = nil, timer: Bool = false, music: Bool = false
    ) -> NotchHome.Content {
        NotchHome.content(
            enabled: enabled, hasNotch: hasNotch, blocked: blocked, hovered: hovered, dropping: dropping,
            notice: notice, timerRunning: timer, musicPlaying: music)
    }

    @Test func collapsedItSaysOneThingAtATime() {
        let notice = NotchHome.Notice(symbol: "airpodspro", title: "AirPods Pro", detail: "82%")
        #expect(content(notice: notice, timer: true, music: true) == .notice(notice), "a notice passes over all")
        #expect(content(timer: true, music: true) == .timer, "a timer outranks music")
        #expect(content(music: true) == .playing)
        #expect(content() == .bare, "nothing going on: a target the size of the notch")
    }

    @Test func hoverOrDraggedFilesOpenIt() {
        #expect(content(hovered: true, timer: true) == .expanded)
        #expect(content(dropping: true) == .expanded)
    }

    @Test func itStaysOutOfTheWay() {
        #expect(content(blocked: true, hovered: true) == .hidden, "the recorder or a Claude Code card is up")
        #expect(content(enabled: false, music: true) == .hidden)
        #expect(content(hasNotch: false, music: true) == .hidden)
        #expect(!NotchHome.Content.bare.isVisible, "bare does not take the notch from Claude Code")
    }

    @Test func openingPicksTheLivelyPage() {
        #expect(NotchHomePage.preferred(hasTrack: true, timerRunning: true, dropping: true) == .shelf)
        #expect(NotchHomePage.preferred(hasTrack: true, timerRunning: true, dropping: false) == .timer)
        #expect(NotchHomePage.preferred(hasTrack: true, timerRunning: false, dropping: false) == .music)
        #expect(NotchHomePage.preferred(hasTrack: false, timerRunning: false, dropping: false) == .today)
        #expect(!NotchHomePage.available(hasTrack: false).contains(.music))
    }

    @Test func aFinishedTimerOutranksADeviceNotice() {
        let device = NotchDeviceAlerts.Notice(symbol: "wifi", title: "Home", detail: "Wi-Fi", at: Date())
        let finished = NotchTimers.Finished(label: "Tea", next: nil, at: Date())
        #expect(NotchHomeManager.notice(device: device, finished: finished)?.title == "Tea")
        #expect(NotchHomeManager.notice(device: device, finished: nil)?.title == "Home")
        #expect(NotchHomeManager.notice(device: nil, finished: nil) == nil)
    }

    @Test func everyBandFitsItsWords() {
        for wing in [NotchHome.wing, NotchHome.timerWing, NotchHome.noticeWing] {
            #expect(wing > NotchDesign.listening.shoulder + NotchDesign.contentInset * 2)
        }
        #expect(NotchHome.noticeWing > NotchHome.timerWing && NotchHome.timerWing > NotchHome.wing)
        let expanded = NotchHome.size(for: .expanded, notchWidth: 185, notchHeight: 32)
        #expect(expanded.height == 32 + NotchHome.Card.height, "the same height on every page")
    }

    @Test func theCoverSitsInsideTheDrawnBody() {
        let notchWidth: CGFloat = 185
        let notchHeight: CGFloat = 32
        let size = NotchHome.size(for: .playing, notchWidth: notchWidth, notchHeight: notchHeight)
        let radii = NotchHome.radii(for: .playing)
        let body = NotchShape(radii).path(in: CGRect(origin: .zero, size: size))
        let inset = radii.shoulder + NotchDesign.contentInset
        let art = NotchHome.artSize
        let cover = CGRect(x: inset, y: (notchHeight - art) / 2, width: art, height: art)
        for corner in [
            CGPoint(x: cover.minX, y: cover.minY), CGPoint(x: cover.maxX, y: cover.minY),
            CGPoint(x: cover.minX, y: cover.maxY), CGPoint(x: cover.maxX, y: cover.maxY),
        ] {
            #expect(body.contains(corner), "cover corner \(corner) is outside the body")
        }
        #expect(cover.maxX <= (size.width - notchWidth) / 2, "the cover is not under the hardware notch")
        #expect(NotchHome.size(for: .bare, notchWidth: notchWidth, notchHeight: notchHeight).width == notchWidth)
    }

    @Test func positionAdvancesOnlyWhilePlaying() {
        let stamp = Date(timeIntervalSince1970: 1_000)
        func track(playing: Bool) -> NotchTrack {
            NotchTrack(
                id: "a", title: "Song", artist: "Artist", isPlaying: playing, duration: 200, elapsed: 50,
                stamp: stamp, rate: playing ? 1 : 0, artwork: nil, tint: .white, bundleID: nil)
        }
        #expect(track(playing: true).position(at: stamp.addingTimeInterval(10)) == 60)
        #expect(track(playing: false).position(at: stamp.addingTimeInterval(10)) == 50)
        #expect(track(playing: true).position(at: stamp.addingTimeInterval(1_000)) == 200, "never past the end")
        #expect(NotchHome.clock(125.9) == "2:05")
    }

    @Test func musicTakesTheNotchFromClaudeCodesWorkingBandButNotFromItsCards() {
        let busy = ClaudeCodeActivity.Status(working: 1, finished: nil)
        let prompt = ClaudeCodeActivity.PermissionPrompt(
            id: UUID(), sessionID: "s1", project: "VoxOs",
            summary: ClaudeCodeToolSummary(title: "Run command", detail: "ls"), toolUseID: nil, received: Date())
        func claude(prompts: [ClaudeCodeActivity.PermissionPrompt]) -> ClaudeCodeNotch.Content {
            ClaudeCodeNotch.content(
                prompts: prompts, status: busy, enabled: true, approvalsEnabled: true, statusEnabled: true,
                recorderVisible: false, homeVisible: true)
        }
        #expect(claude(prompts: []) == .hidden)
        #expect(claude(prompts: [prompt]).isCard)
    }

    @Test func darkCoversStillGiveVisibleBars() {
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor(red: 0.05, green: 0.02, blue: 0.1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let tint = NSColor(NotchHomeManager.tint(of: image)).usingColorSpace(.deviceRGB)
        var brightness: CGFloat = 0
        tint?.getHue(nil, saturation: nil, brightness: &brightness, alpha: nil)
        #expect(brightness >= 0.85)
    }

    // MARK: Shuffle and repeat

    @Test func shuffleAndRepeatAreReadFromMusicAndSpotify() {
        #expect(NotchPlaybackModes.parseMusic("true, one") == .init(shuffle: true, repeatMode: .one))
        #expect(NotchPlaybackModes.parseMusic("false, off\n") == .init(shuffle: false, repeatMode: .off))
        #expect(NotchPlaybackModes.parseSpotify("false, true") == .init(shuffle: false, repeatMode: .all))
        #expect(NotchPlaybackModes.parseMusic("") == nil, "an error reads as unknown, not as off")
        #expect(NotchPlaybackModes.canReadState(of: "com.spotify.client"))
        #expect(!NotchPlaybackModes.canReadState(of: "com.google.Chrome"), "other players get a plain toggle")
    }

    @Test func repeatCyclesLikeMusicDoes() {
        #expect(NotchPlaybackModes.Repeat.off.next == .all)
        #expect(NotchPlaybackModes.Repeat.all.next == .one)
        #expect(NotchPlaybackModes.Repeat.one.next == .off)
        #expect(
            NotchPlaybackModes.repeatScript(for: "com.apple.Music", to: .one)
                == #"tell application id "com.apple.Music" to set song repeat to one"#)
    }

    // MARK: Several players

    @Test func musicAndSpotifyAnnounceThemselves() {
        let now = Date()
        let music = NotchPlayers.parseMusic(
            ["Name": "Loser", "Artist": "Charlie Puth", "Player State": "Playing", "Total Time": 204_000], now: now)
        #expect(music?.title == "Loser")
        #expect(music?.isPlaying == true)
        #expect(music?.duration == 204)
        #expect(NotchPlayers.parseMusic(["Name": "Loser", "Player State": "Stopped"], now: now) == nil)

        let spotify = NotchPlayers.parseSpotify(
            [
                "Name": "Song", "Artist": "Band", "Player State": "Paused", "Duration": 180_000,
                "Playback Position": 42.5,
            ],
            now: now)
        #expect(spotify?.isPlaying == false)
        #expect(spotify?.duration == 180)
        #expect(spotify?.position == 42.5)
    }

    @Test func appleScriptStateKeepsCommasInTitles() {
        let sep = NotchPlayers.separator
        let output = ["Hello, World", "Artist", "playing", "213.5", "12.25"].joined(separator: sep)
        let entry = NotchPlayers.parseState(output, bundleID: NotchPlayers.music, now: Date())
        #expect(entry?.title == "Hello, World")
        #expect(entry?.duration == 213.5)
        let spotify = NotchPlayers.parseState(
            ["A", "B", "paused", "180000", "3"].joined(separator: sep), bundleID: NotchPlayers.spotify, now: Date())
        #expect(spotify?.duration == 180, "Spotify reports milliseconds")
        #expect(NotchPlayers.parseState("stopped", bundleID: NotchPlayers.music, now: Date()) == nil)
    }

    private func track(_ bundle: String, playing: Bool) -> NotchTrack {
        NotchTrack(
            id: bundle, title: bundle, artist: "", isPlaying: playing, duration: nil, elapsed: nil, stamp: Date(),
            rate: 0, artwork: nil, tint: .white, bundleID: bundle)
    }

    @Test func thePickedPlayerStaysShownAndOtherwiseThePlayingOne() {
        let tracks = [track("com.apple.Music", playing: false), track("com.google.Chrome", playing: true)]
        #expect(NotchHomeManager.shown(tracks, selected: nil)?.bundleID == "com.google.Chrome")
        #expect(NotchHomeManager.shown(tracks, selected: "com.apple.Music")?.bundleID == "com.apple.Music")
        #expect(
            NotchHomeManager.shown(tracks, selected: "com.spotify.client")?.bundleID == "com.google.Chrome",
            "a picked player that went away gives way")
    }

    // MARK: Swipes

    @Test func swipingTowardTheMiddlePutsABandAway() {
        func swipe(_ x: CGFloat, _ dx: CGFloat, _ dy: CGFloat) -> NotchHomeManager.Swipe {
            NotchHomeManager.swipe(startX: x, width: 300, fingerDX: dx, fingerDY: dy, expanded: false)
        }
        #expect(swipe(250, -60, 4) == .dismiss, "right half, right to left")
        #expect(swipe(50, 60, -3) == .dismiss, "left half, left to right")
        #expect(swipe(250, 60, 0) == .restore, "outward brings a swiped band back")
        #expect(swipe(50, -60, 0) == .restore)
        #expect(swipe(250, -10, 0) == .none, "a nudge")
        #expect(swipe(150, 2, -50) == .none, "up and down mean nothing to a band")
        #expect(swipe(250, 45, 0) == .none, "collapsed, a short sideways scroll is not a swipe")
        #expect(swipe(250, 70, 40) == .none, "a scroll drifting across the band leaves it alone")
    }

    /// Let go far enough, or with a flick the same way, and the page goes; else it settles back.
    @Test func aPageGoesOnlyWhenLetGoFarEnoughOrFlicked() {
        #expect(NotchHomeManager.commitsPage(dx: -100, flick: 0, width: 480), "past a fifth")
        #expect(!NotchHomeManager.commitsPage(dx: -60, flick: -1, width: 480), "a slow short drag settles back")
        #expect(NotchHomeManager.commitsPage(dx: 40, flick: 9, width: 480), "a flick its way")
        #expect(!NotchHomeManager.commitsPage(dx: 40, flick: -9, width: 480), "a flick back the other way")
        #expect(!NotchHomeManager.commitsPage(dx: 10, flick: 12, width: 480), "too short to be a swipe")
        #expect(!NotchHomeManager.commitsPage(dx: 0, flick: 0, width: 480))
    }

    @Test func openSidewaysTurnsPagesAndUpDownChangesPlayer() {
        func swipe(_ dx: CGFloat, _ dy: CGFloat) -> NotchHomeManager.Swipe {
            NotchHomeManager.swipe(startX: 400, width: 480, fingerDX: dx, fingerDY: dy, expanded: true)
        }
        #expect(swipe(-60, 3) == .nextPage)
        #expect(swipe(60, 3) == .previousPage)
        #expect(swipe(2, -50) == .nextPlayer)
        #expect(swipe(2, 50) == .previousPlayer)
        func page(_ from: NotchHomePage, _ forward: Bool, track: Bool, extras: Bool = false) -> NotchHomePage {
            NotchHomeManager.page(after: from, forward: forward, hasTrack: track, sound: extras, mirror: extras)
        }
        #expect(page(.shelf, true, track: true) == .music, "wraps round")
        #expect(page(.today, false, track: false) == .shelf, "no Music page")
        #expect(page(.music, true, track: true) == .today)
        #expect(page(.shelf, true, track: true, extras: true) == .sound, "Sound and Mirror when on")
        #expect(page(.mirror, true, track: false, extras: true) == .today)
    }

    @Test func aSwipedBandStaysAwayUntilItWouldSaySomethingElse() {
        let first = NotchHomeManager.bandKey(.playing, track: track("a", playing: true), timer: nil)
        let next = NotchHomeManager.bandKey(.playing, track: track("b", playing: true), timer: nil)
        #expect(first != nil && first != next)
        #expect(NotchHomeManager.bandKey(.bare, track: nil, timer: nil) == nil)
        #expect(
            NotchHomeManager.bandKey(.expanded, track: nil, timer: nil) == nil, "the open card is closed, not hidden")
    }

    /// The collapsed band moves while music plays without listening to it: always in range, and
    /// the bars never in step.
    @Test func ambientBarsMoveWithinRangeAndOutOfStep() {
        let now = NotchLevelBars.ambientLevels(count: 4, at: 100)
        let later = NotchLevelBars.ambientLevels(count: 4, at: 100.2)
        #expect(now.allSatisfy { $0 >= 0.15 && $0 <= 1 })
        #expect(now != later, "it moves")
        #expect(Set(now.map { ($0 * 100).rounded() }).count > 1, "not all the same height")
    }

    // MARK: Menu bar

    @Test func aBandOnlyGrowsIntoFreeMenuBar() {
        // Notch 663…848; menus end at 595, the first status item starts at 930.
        let wing = NotchMenuBarClearance.allowedWing(
            notchMinX: 663, notchMaxX: 848, menusMaxX: 595, statusItemsMinX: 930)
        #expect(wing == 68 - NotchMenuBarClearance.margin, "the narrower side decides")
        #expect(NotchHomeManager.fits(.playing, allowedWing: wing), "music needs \(NotchHome.wing)")
        #expect(!NotchHomeManager.fits(.timer, allowedWing: wing), "a timer needs \(NotchHome.timerWing)")
        #expect(NotchHomeManager.fits(.notice(.init(symbol: "wifi", title: "x", detail: nil)), allowedWing: 0))
        #expect(
            NotchMenuBarClearance.allowedWing(notchMinX: 663, notchMaxX: 848, menusMaxX: nil, statusItemsMinX: nil)
                == nil, "nothing measured, nothing held back")
        #expect(NotchHomeManager.fits(.timer, allowedWing: nil))
    }

    /// Only the hardware notch opens the card; the band's wings, which the pointer crosses on the
    /// way to the menu bar, do not.
    @Test func onlyTheTopOfTheNotchOpensIt() {
        let notch = CGSize(width: 185, height: 32)
        #expect(NotchHomeView.opensAt(CGPoint(x: 150, y: 0), width: 301, notch: notch), "top of the screen")
        #expect(NotchHomeView.opensAt(CGPoint(x: 150, y: 5), width: 301, notch: notch), "top strip")
        #expect(!NotchHomeView.opensAt(CGPoint(x: 20, y: 0), width: 301, notch: notch), "left wing: the cover")
        #expect(!NotchHomeView.opensAt(CGPoint(x: 285, y: 0), width: 301, notch: notch), "right wing: the bars")
        #expect(!NotchHomeView.opensAt(CGPoint(x: 150, y: 20), width: 301, notch: notch), "lower notch, near tabs")
        #expect(!NotchHomeView.opensAt(CGPoint(x: 150, y: 34), width: 301, notch: notch), "just under the notch")
    }

    // MARK: Battery

    @Test func liveBarsListenOnlyWhenPowerAllows() {
        #expect(NotchHome.liveBars(enabled: true, lowPowerMode: false, onBattery: false, allowedOnBattery: false))
        #expect(NotchHome.liveBars(enabled: true, lowPowerMode: false, onBattery: true, allowedOnBattery: true))
        #expect(
            !NotchHome.liveBars(enabled: true, lowPowerMode: false, onBattery: true, allowedOnBattery: false),
            "on battery when the user said not to")
        #expect(
            !NotchHome.liveBars(enabled: true, lowPowerMode: true, onBattery: false, allowedOnBattery: true),
            "Low Power Mode always wins")
        #expect(!NotchHome.liveBars(enabled: false, lowPowerMode: false, onBattery: false, allowedOnBattery: true))
    }

    @Test func ambientBarsTickSlowerThanLiveOnes() {
        #expect(LevelBarsNSView.interval(for: .live) == 1.0 / 30)
        #expect(LevelBarsNSView.interval(for: .ambient) == 1.0 / 20)
    }

    @Test func barsStopTickingOutsideAWindow() {
        let view = LevelBarsNSView(bars: 4, barWidth: 3, spacing: 2, maxHeight: 14)
        view.source = .ambient
        #expect(!view.isTicking, "no window: nothing can see the bars")
    }

    // MARK: Displays

    @Test func theNotchLivesOnTheNotchedDisplayElseTheMainOneOrTheOneInUse() {
        let laptop: (id: CGDirectDisplayID, hasNotch: Bool) = (1, true)
        let monitor: (id: CGDirectDisplayID, hasNotch: Bool) = (2, false)
        #expect(NotchScreens.choose([monitor, laptop], active: nil) == 1, "the notched display")
        #expect(NotchScreens.choose([monitor], active: nil) == 2, "no notch anywhere: the main display")
        #expect(NotchScreens.choose([monitor, laptop], active: 2) == 2, "following the display in use")
        #expect(NotchScreens.choose([laptop], active: 9) == 1, "a display that is gone is not followed")
        #expect(NotchScreens.choose([], active: nil) == nil)
    }
}
