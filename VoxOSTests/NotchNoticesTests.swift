import CoreAudio
import Foundation
import IOKit.ps
import Testing

@testable import VoxOS

/// What the notch says about the Mac itself: the power adapter and battery, where the sound
/// goes, a microphone or camera in use, and the next meeting.
@Suite
@MainActor
struct NotchNoticesTests {

    // MARK: Battery

    private static func battery(_ percent: Int, adapter: Bool, charging: Bool = false) -> PowerState.Battery {
        PowerState.Battery(percent: percent, charging: charging, onAdapter: adapter)
    }

    @Test func theAdapterGoingInOrOutIsSaid() {
        let plugged = NotchDeviceAlerts.batteryNotice(
            from: Self.battery(54, adapter: false), to: Self.battery(54, adapter: true, charging: true))
        #expect(plugged?.key == "power-on")
        #expect(plugged?.detail == "54%")
        let unplugged = NotchDeviceAlerts.batteryNotice(
            from: Self.battery(80, adapter: true), to: Self.battery(80, adapter: false))
        #expect(unplugged?.key == "power-off")
        #expect(unplugged?.symbol == "battery.75percent")
        #expect(
            NotchDeviceAlerts.batteryNotice(
                from: Self.battery(60, adapter: false), to: Self.battery(59, adapter: false))
                == nil, "a percent on its own is not news")
        #expect(NotchDeviceAlerts.batteryNotice(from: nil, to: Self.battery(50, adapter: false)) == nil)
    }

    @Test func aLowBatteryIsSaidOncePerLevelAndOnlyOnBattery() {
        let low = NotchDeviceAlerts.batteryNotice(
            from: Self.battery(21, adapter: false), to: Self.battery(20, adapter: false))
        #expect(low?.key == "battery-low-20")
        #expect(
            NotchDeviceAlerts.batteryNotice(
                from: Self.battery(20, adapter: false), to: Self.battery(19, adapter: false))
                == nil, "already said at 20")
        let jump = NotchDeviceAlerts.batteryNotice(
            from: Self.battery(12, adapter: false), to: Self.battery(4, adapter: false))
        #expect(jump?.key == "battery-low-5", "the lowest level crossed")
        #expect(
            NotchDeviceAlerts.batteryNotice(from: Self.battery(21, adapter: true), to: Self.battery(20, adapter: true))
                == nil, "charging up or holding is not low")
    }

    @Test func batteryLevelsReadFromThePowerSource() {
        let battery = PowerState.battery(from: [
            kIOPSCurrentCapacityKey: 45, kIOPSMaxCapacityKey: 90, kIOPSIsChargingKey: true,
            kIOPSPowerSourceStateKey: kIOPSACPowerValue,
        ])
        #expect(battery == PowerState.Battery(percent: 50, charging: true, onAdapter: true))
        #expect(PowerState.battery(from: [kIOPSCurrentCapacityKey: 45]) == nil)
        #expect(NotchDeviceAlerts.batterySymbol(3) == "battery.0percent")
        #expect(NotchDeviceAlerts.batterySymbol(100) == "battery.100percent")
    }

    // MARK: Sound output

    @Test func outputIconsComeFromHowTheDeviceIsConnected() {
        func symbol(_ name: String, _ transport: UInt32) -> String {
            NotchAudioOutput.symbol(for: .init(id: 1, name: name, transport: transport))
        }
        #expect(symbol("Someone's AirPods Pro", kAudioDeviceTransportTypeBluetooth) == "airpodspro")
        #expect(symbol("Desk Headset", kAudioDeviceTransportTypeBluetoothLE) == "headphones")
        #expect(symbol("Living Room", kAudioDeviceTransportTypeAirPlay) == "airplayaudio")
        #expect(symbol("Display", kAudioDeviceTransportTypeHDMI) == "tv")
        #expect(symbol("External Headphones", kAudioDeviceTransportTypeBuiltIn) == "headphones")
        #expect(symbol("Speakers", kAudioDeviceTransportTypeBuiltIn) == "speaker.wave.2.fill")
        #expect(symbol("Interface", kAudioDeviceTransportTypeUSB) == "hifispeaker.fill")
    }

    @Test func plumbingDevicesAreNotAnnounced() {
        #expect(NotchAudioOutput.isWorthANotice(transport: kAudioDeviceTransportTypeBluetooth))
        #expect(NotchAudioOutput.isWorthANotice(transport: kAudioDeviceTransportTypeBuiltIn))
        #expect(!NotchAudioOutput.isWorthANotice(transport: kAudioDeviceTransportTypeVirtual))
        #expect(!NotchAudioOutput.isWorthANotice(transport: kAudioDeviceTransportTypeAggregate))
    }

    // MARK: Meetings

    private static let nine = Date(timeIntervalSince1970: 1_800_000_000)

    private static func event(
        _ id: String, startsIn minutes: Double, length: Double = 30, allDay: Bool = false, link: URL? = nil
    ) -> NotchToday.Event {
        let start = nine.addingTimeInterval(minutes * 60)
        return NotchToday.Event(
            id: id, title: id, start: start, end: start.addingTimeInterval(length * 60), isAllDay: allDay,
            color: .white, joinURL: link)
    }

    @Test func theCountdownCoversFiveMinutesEitherSideOfTheStart() {
        let soon = Self.event("Standup", startsIn: 4)
        let later = Self.event("Review", startsIn: 60)
        var found = NotchToday.meeting(in: [later, soon], now: Self.nine)
        #expect(found.current?.id == "Standup")
        #expect(found.next?.id == "Review")
        found = NotchToday.meeting(in: [Self.event("Early", startsIn: 6)], now: Self.nine)
        #expect(found.current == nil, "more than five minutes out")
        #expect(found.next?.id == "Early")
        #expect(NotchToday.meeting(in: [Self.event("Late", startsIn: -4)], now: Self.nine).current?.id == "Late")
        #expect(NotchToday.meeting(in: [Self.event("Gone", startsIn: -6)], now: Self.nine).current == nil)
        #expect(
            NotchToday.meeting(in: [Self.event("Holiday", startsIn: 2, allDay: true)], now: Self.nine).current == nil)
        #expect(
            NotchToday.meeting(in: [Self.event("Short", startsIn: -3, length: 2)], now: Self.nine).current == nil,
            "a meeting that has ended")
    }

    @Test func theNextCheckIsWhenTheAnswerCanChange() {
        let soon = Self.event("Standup", startsIn: 4)
        let later = Self.event("Review", startsIn: 60)
        #expect(
            NotchToday.nextCheck(current: soon, next: later, now: Self.nine)
                == soon.start.addingTimeInterval(NotchToday.meetingGrace))
        #expect(
            NotchToday.nextCheck(current: nil, next: later, now: Self.nine)
                == later.start.addingTimeInterval(-NotchToday.meetingLead))
        #expect(NotchToday.nextCheck(current: nil, next: nil, now: Self.nine) == nil, "nothing to wait for")
    }

    @Test func theCountdownRoundsUpAndSaysNowFromTheStart() {
        #expect(NotchToday.countdown(to: Self.nine.addingTimeInterval(270), now: Self.nine) == "5m")
        #expect(NotchToday.countdown(to: Self.nine.addingTimeInterval(60), now: Self.nine) == "1m")
        #expect(NotchToday.countdown(to: Self.nine.addingTimeInterval(1), now: Self.nine) == "1m")
        #expect(NotchToday.countdown(to: Self.nine, now: Self.nine) == "now")
    }

    @Test func onlyVideoCallLinksAreAWayIn() {
        let zoom = NotchToday.joinURL(in: [nil, "Room 4", "Join: https://example.zoom.us/j/123456?pwd=x thanks"])
        #expect(zoom?.host == "example.zoom.us")
        #expect(NotchToday.joinURL(in: ["https://meet.google.com/abc-defg-hij"])?.host == "meet.google.com")
        #expect(
            NotchToday.joinURL(in: [
                "Agenda: https://docs.example.com/a", "https://teams.microsoft.com/l/meetup-join/x",
            ])?
            .host == "teams.microsoft.com", "the first call link, not the first link")
        #expect(NotchToday.joinURL(in: ["https://notzoom.us/j/1", "https://example.com"]) == nil)
        #expect(NotchToday.joinURL(in: [nil, ""]) == nil)
    }

    @Test func joinIsOfferedAroundTheCallOnly() {
        let link = URL(string: "https://meet.google.com/abc-defg-hij")
        #expect(NotchToday.canJoin(Self.event("Call", startsIn: 8, link: link), now: Self.nine))
        #expect(!NotchToday.canJoin(Self.event("Call", startsIn: 30, link: link), now: Self.nine))
        #expect(!NotchToday.canJoin(Self.event("Call", startsIn: -40, link: link), now: Self.nine), "over")
        #expect(!NotchToday.canJoin(Self.event("Room", startsIn: 2), now: Self.nine), "no link")
    }

    // MARK: What the band says

    @Test func aMeetingAndACallComeBetweenANoticeAndATimer() {
        let notice = NotchHome.Notice(symbol: "wifi", title: "Home", detail: nil)
        let meeting = Self.event("Standup", startsIn: 3)
        let call = NotchPrivacy.State(microphone: true, camera: true, microphoneApp: "com.example.calls", muted: false)
        func content(
            notice: NotchHome.Notice? = nil, meeting: NotchToday.Event? = nil, privacy: NotchPrivacy.State? = nil
        )
            -> NotchHome.Content
        {
            NotchHome.content(
                enabled: true, hasNotch: true, blocked: false, hovered: false, dropping: false, notice: notice,
                timerRunning: true, musicPlaying: true, meeting: meeting, privacy: privacy)
        }
        #expect(content(notice: notice, meeting: meeting, privacy: call) == .notice(notice))
        #expect(content(meeting: meeting, privacy: call) == .meeting(meeting))
        #expect(content(privacy: call) == .privacy(call))
        #expect(content(privacy: .idle) == .timer, "nothing in use, nothing said")
        #expect(NotchHomePage.preferred(hasTrack: true, timerRunning: true, dropping: false, meeting: true) == .today)
        #expect(NotchHomePage.preferred(hasTrack: true, timerRunning: true, dropping: true, meeting: true) == .shelf)
    }

    @Test func aCallBandLastsSoItMustFitButAMeetingNeedNot() {
        let call = NotchHome.Content.privacy(NotchPrivacy.State(microphone: true))
        #expect(!NotchHomeManager.fits(call, allowedWing: NotchHome.privacyWing - 1))
        #expect(NotchHomeManager.fits(call, allowedWing: NotchHome.privacyWing))
        #expect(NotchHomeManager.fits(.meeting(Self.event("Standup", startsIn: 3)), allowedWing: 0))
    }

    @Test func mutingDoesNotBringBackABandThatWasPutAway() {
        let open = NotchPrivacy.State(microphone: true, microphoneApp: "com.example.calls", muted: false)
        var muted = open
        muted.muted = true
        #expect(
            NotchHomeManager.bandKey(.privacy(open), track: nil, timer: nil)
                == NotchHomeManager.bandKey(.privacy(muted), track: nil, timer: nil))
        var withCamera = open
        withCamera.camera = true
        #expect(
            NotchHomeManager.bandKey(.privacy(open), track: nil, timer: nil)
                != NotchHomeManager.bandKey(.privacy(withCamera), track: nil, timer: nil), "a camera is news")
    }

    // MARK: Microphone

    /// Measured on macOS 26: Siri's voice trigger reports running input with no microphone running
    /// and no orange dot; the band showed a microphone while only music played.
    @Test func onlyAMicrophoneThatRunsForSomeoneElseCounts() {
        let me: pid_t = 100
        let trigger = (pid: pid_t(848), bundleID: String?("com.apple.CoreSpeech"))
        let call = (pid: pid_t(900), bundleID: String?("com.example.calls"))
        let dictation = (pid: me, bundleID: String?("com.example.voxos"))
        #expect(NotchPrivacy.listeners([trigger], me: me, inputRunning: false).isEmpty)
        #expect(NotchPrivacy.listeners([trigger], me: me, inputRunning: true).isEmpty, "the voice trigger never counts")
        #expect(NotchPrivacy.listeners([call], me: me, inputRunning: false).isEmpty, "no microphone runs")
        #expect(NotchPrivacy.listeners([trigger, call, dictation], me: me, inputRunning: true).map(\.pid) == [900])
        #expect(NotchPrivacy.listeners([dictation], me: me, inputRunning: true).isEmpty, "VoxOS's own dictation")
    }

    // MARK: Volume and brightness

    @Test func keysStepLikeMacOSDoes() {
        // Expected values built from the step itself: a bare literal is typed apart from the Float.
        let s = NotchHUD.step
        let f = NotchHUD.fineStep
        #expect(NotchHUD.stepped(5 * s, by: s) == 6 * s)
        #expect(NotchHUD.stepped(5 * s, by: -s) == 4 * s)
        #expect(NotchHUD.stepped(Float(0.37), by: s) == 6 * s, "between steps: up to the next one")
        #expect(NotchHUD.stepped(Float(0.37), by: -s) == 5 * s, "and down to the one below")
        #expect(NotchHUD.stepped(6 * s - Float(0.000_001), by: s) == 7 * s, "a rounding error under a step is on it")
        #expect(NotchHUD.stepped(Float(1), by: s) == Float(1))
        #expect(NotchHUD.stepped(Float(0), by: -s) == Float(0))
        #expect(NotchHUD.stepped(32 * f, by: f) == 33 * f, "Option-Shift: a quarter step")
    }

    @Test func mediaKeysAreReadFromTheEventData() {
        // NX_KEYTYPE_SOUND_UP pressed, NX_KEYTYPE_BRIGHTNESS_DOWN released, mute held (repeat).
        #expect(MediaKeyTap.decode(0x0000_0A00).map { "\($0.key)\($0.down)" } == "volumeUptrue")
        #expect(MediaKeyTap.decode(0x0003_0B00).map { "\($0.key)\($0.down)" } == "brightnessDownfalse")
        #expect(MediaKeyTap.decode(0x0007_0A01)?.repeating == true)
        #expect(MediaKeyTap.decode(0x0010_0A00) == nil, "play/pause is left to macOS")
        #expect(MediaKeyTap.decode(0x0000_0000) == nil, "not a press or a release")
    }

    @Test func theLevelShowsWhatChanged() {
        #expect(NotchHUD.Level(kind: .volume, value: 0.2).symbol == "speaker.wave.1.fill")
        #expect(NotchHUD.Level(kind: .volume, value: 0.9).symbol == "speaker.wave.3.fill")
        #expect(NotchHUD.Level(kind: .volume, value: 0.5, muted: true).symbol == "speaker.slash.fill")
        #expect(NotchHUD.Level(kind: .brightness, value: 0.8).symbol == "sun.max.fill")
        let level = NotchHUD.Level(kind: .volume, value: 0.5)
        let notice = NotchHome.Notice(symbol: "wifi", title: "Home", detail: nil)
        #expect(
            NotchHome.content(
                enabled: true, hasNotch: true, blocked: false, hovered: false, dropping: false, notice: notice,
                timerRunning: true, musicPlaying: true, level: level) == .level(level), "a key just pressed comes first"
        )
        #expect(
            NotchHome.content(
                enabled: true, hasNotch: true, blocked: false, hovered: true, dropping: false, notice: nil,
                timerRunning: false, musicPlaying: false, level: level) == .expanded, "open, the card stays open")
    }

    // MARK: Focus

    @Test func theActiveFocusIsReadFromItsStore() {
        let assertions: [String: Any] = [
            "data": [
                [
                    "storeAssertionRecords": [
                        [
                            "assertionStartDateTimestamp": 100.0,
                            "assertionDetails": ["assertionDetailsModeIdentifier": "old"],
                        ],
                        [
                            "assertionStartDateTimestamp": 200.0,
                            "assertionDetails": ["assertionDetailsModeIdentifier": "com.example.work"],
                        ],
                    ]
                ]
            ]
        ]
        #expect(NotchFocus.activeModeID(in: assertions) == "com.example.work", "the newest one")
        #expect(NotchFocus.activeModeID(in: ["data": [["storeInvalidationRecords": []]]]) == nil, "none on")
        #expect(NotchFocus.activeModeID(in: "not json we know") == nil)
        let modes: [String: Any] = [
            "data": [
                [
                    "modeConfigurations": [
                        "com.example.work": ["mode": ["name": "Work", "symbolImageName": "briefcase"]]
                    ]
                ]
            ]
        ]
        #expect(
            NotchFocus.mode("com.example.work", in: modes)
                == .init(id: "com.example.work", name: "Work", symbol: "briefcase"))
        #expect(NotchFocus.mode("missing", in: modes) == nil)
    }

    // MARK: Downloads, keep awake

    @Test func aDownloadIsNamedWithoutItsBrowserExtension() {
        #expect(NotchDownloads.displayName(of: URL(fileURLWithPath: "/tmp/Report.pdf.crdownload")) == "Report.pdf")
        #expect(NotchDownloads.displayName(of: URL(fileURLWithPath: "/tmp/Movie.mov.download")) == "Movie.mov")
        #expect(NotchDownloads.displayName(of: URL(fileURLWithPath: "/tmp/notes.txt")) == "notes.txt")
        let item = NotchDownloads.Item(id: ObjectIdentifier(NSObject()), name: "a.zip", fraction: 0.4)
        let content = NotchHome.content(
            enabled: true, hasNotch: true, blocked: false, hovered: false, dropping: false, notice: nil,
            timerRunning: true, musicPlaying: true, downloads: [item, item])
        #expect(content == .download(item, others: 1), "a download comes before a timer")
        #expect(NotchHomeManager.downloadNotice("a.zip")?.detail == "Downloaded")
    }

    @Test func keepingAwakeStopsBeforeTheBatteryRunsOut() {
        #expect(NotchKeepAwake.shouldLetGo(PowerState.Battery(percent: 9, charging: false, onAdapter: false)))
        #expect(!NotchKeepAwake.shouldLetGo(PowerState.Battery(percent: 9, charging: true, onAdapter: true)))
        #expect(!NotchKeepAwake.shouldLetGo(PowerState.Battery(percent: 50, charging: false, onAdapter: false)))
    }

    // MARK: Per-app volume

    /// The tap gives interleaved stereo, the output wants one buffer per channel: each sample
    /// lands in its channel at the level asked for.
    @Test func anAppsSoundIsCopiedAtItsLevel() {
        var source: [Float] = [1, -1, 0.5, -0.5]  // two frames, left and right interleaved
        var left: [Float] = [9, 9]
        var right: [Float] = [9, 9]
        source.withUnsafeMutableBytes { sourceBytes in
            left.withUnsafeMutableBytes { leftBytes in
                right.withUnsafeMutableBytes { rightBytes in
                    let input = AudioBufferList.allocate(maximumBuffers: 1)
                    input[0] = AudioBuffer(
                        mNumberChannels: 2, mDataByteSize: UInt32(sourceBytes.count), mData: sourceBytes.baseAddress)
                    let output = AudioBufferList.allocate(maximumBuffers: 2)
                    output[0] = AudioBuffer(
                        mNumberChannels: 1, mDataByteSize: UInt32(leftBytes.count), mData: leftBytes.baseAddress)
                    output[1] = AudioBuffer(
                        mNumberChannels: 1, mDataByteSize: UInt32(rightBytes.count), mData: rightBytes.baseAddress)
                    AppVolumeTap.copy(input.unsafePointer, to: output.unsafeMutablePointer, gain: 0.5)
                    free(input.unsafeMutablePointer)
                    free(output.unsafeMutablePointer)
                }
            }
        }
        #expect(left == [0.5, 0.25])
        #expect(right == [-0.5, -0.25])
    }
}
