import AVFoundation
import AppKit
import Foundation
import os

/// Notes for a call: its sound is recorded while it lasts, then transcribed with who spoke,
/// summarized with action items, and saved to History.
///
/// Both sides are recorded: what the Mac plays, so the other people in the call, and the
/// microphone, so you, mixed together when the call ends. Include My Microphone, on by
/// default, can leave the microphone out. It starts when Join is clicked in the notch or on the
/// Calendar page with Meeting Notes on, or from Start Meeting Notes in the menu bar. It stops at
/// the meeting's end, or later while the call app still has the microphone, or from the menu
/// bar. A recording under way when VoxOS quits is saved and written up at the next launch.
@MainActor
final class MeetingNotes: ObservableObject {
    static let shared = MeetingNotes()

    struct Session: Equatable {
        let title: String
        let startedAt: Date
        let scheduledEnd: Date
        let url: URL
        /// The microphone's own recording, mixed in when the call ends.
        var microphoneURL: URL? = nil
        /// Started from the menu bar: runs until stopped there, up to `maxLength`.
        var endsByHand = false
    }

    @Published private(set) var session: Session?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.meetingNotesEnabled) }
    static var includesMicrophone: Bool { includesMicrophone(in: .standard) }

    /// A meeting has two sides, so the microphone is recorded unless the user turned it off.
    nonisolated static func includesMicrophone(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: DefaultsKeys.meetingNotesIncludeMicrophone) as? Bool ?? true
    }

    /// How long past its scheduled end a call is followed while it still has the microphone.
    nonisolated static let maxOverrun: TimeInterval = 60 * 60
    /// The longest a recording runs, whatever the calendar says.
    nonisolated static let maxLength: TimeInterval = 4 * 60 * 60
    /// Shorter than this is a call that never happened; nothing is saved.
    nonisolated static let minLength: TimeInterval = 30

    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "MeetingNotes")
    private weak var engine: VoxOSEngine?
    private var checkTimer: Timer?
    private var microphone: MeetingMicrophone?

    private init() {}

    /// Kept beside the transcripts' recordings, so a meeting under way at quit survives it.
    nonisolated static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.achyuthkp.VoxOS")
            .appendingPathComponent("Meetings")
    }

    func configure(engine: VoxOSEngine) {
        self.engine = engine
        guard !ProcessIdentity.isTestHost else { return }
        writeUpPendingMeetings()
    }

    // MARK: Starting

    /// Called when the user joins a call from VoxOS.
    func joined(title: String, end: Date) {
        guard Self.isEnabled else { return }
        begin(title: title, end: end, byHand: false)
    }

    /// From the menu bar: the meeting in the calendar now, or a call joined some other way.
    func startByHand(now: Date = Date()) {
        let title =
            NotchToday.shared.meeting?.title
            ?? String(localized: "Meeting at \(now.formatted(date: .omitted, time: .shortened))")
        begin(title: title, end: now, byHand: true)
    }

    private func begin(title: String, end: Date, byHand: Bool) {
        guard session == nil, !ProcessIdentity.isTestHost else { return }
        guard !SystemAudioCaptureController.shared.isCapturing else {
            NotificationManager.shared.showNotification(
                title: String(localized: "Meeting notes did not start: system audio is already being captured."),
                type: .warning)
            return
        }
        Task { await start(title: title, end: end, byHand: byHand) }
    }

    private func start(title: String, end: Date, byHand: Bool) async {
        let id = UUID().uuidString
        let url = Self.directory.appendingPathComponent("meeting_\(id).wav")
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try await SystemAudioCaptureService.shared.startCapture(to: url)
        } catch {
            logger.error("Meeting notes could not start: \(error, privacy: .public)")
            NotificationManager.shared.showNotification(
                title: String(localized: "Meeting notes need System Audio Recording, in System Settings → Privacy."),
                type: .warning)
            return
        }
        let now = Date()
        var session = Session(
            title: title, startedAt: now, scheduledEnd: max(end, now), url: url, endsByHand: byHand)
        let showsLive = MeetingLiveTranscript.isEnabled
        if Self.includesMicrophone {
            session.microphoneURL = startMicrophone(
                to: Self.directory.appendingPathComponent("meeting_\(id)_mic.wav"), live: showsLive)
        }
        self.session = session
        ActivityTrail.mark("meeting notes started")
        if showsLive, let engine, let mode = ModeManager.shared.currentEffectiveConfiguration {
            MeetingLiveTranscript.shared.start(title: title, engine: engine, mode: mode, microphone: microphone)
            LiveTranscriptWindow.shared.show()
        }
        NotificationManager.shared.showNotification(
            title: session.microphoneURL == nil
                ? String(localized: "Taking notes on “\(title)”: recording the call’s sound, not your microphone.")
                : String(localized: "Taking notes on “\(title)”: recording the call and your microphone."),
            type: .info, duration: 4)
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            Task { @MainActor in MeetingNotes.shared.check() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
    }

    /// Records the default microphone in the system recording's format, so the two mix sample
    /// for sample. Nil, and the call is recorded without it, when the microphone cannot start.
    private func startMicrophone(to url: URL, live: Bool) -> URL? {
        let recorder = MeetingMicrophone()
        do {
            try recorder.start(to: url, live: live)
        } catch {
            logger.error("Meeting notes could not record the microphone, so only the call: \(error, privacy: .public)")
            return nil
        }
        microphone = recorder
        return url
    }

    // MARK: Stopping

    /// Stops when the meeting is over: past its end and the call has let go of the microphone.
    private func check(now: Date = Date()) {
        guard let session else { return }
        let callStillOn = NotchPrivacy.isEnabled ? NotchPrivacy.shared.state.microphone : nil
        if !Self.shouldKeepRecording(session: session, now: now, callStillOn: callStillOn) {
            Task { await stop() }
        }
    }

    /// Whether a recording carries on: one started by hand until stopped; otherwise until its
    /// scheduled end, then only while the call app still has the microphone (unknown counts as
    /// no) and for at most `maxOverrun`; never past `maxLength`.
    nonisolated static func shouldKeepRecording(session: Session, now: Date, callStillOn: Bool?) -> Bool {
        if now.timeIntervalSince(session.startedAt) >= maxLength { return false }
        if session.endsByHand || now < session.scheduledEnd { return true }
        return callStillOn == true && now.timeIntervalSince(session.scheduledEnd) < maxOverrun
    }

    /// Stops recording and hands the call to Transcribe Audio with the meeting notes prompt.
    func stop() async {
        guard let finished = await finishRecording() else { return }
        writeUp(finished.url, title: finished.title)
        NotificationManager.shared.showNotification(
            title: String(localized: "Writing up “\(finished.title)”. It will be in History when done."),
            type: .info, duration: 4)
    }

    /// VoxOS is quitting: the recording is saved and written up at the next launch.
    func stopForQuit() async {
        guard let finished = await finishRecording() else { return }
        var pending = Self.pendingMeetings()
        pending.append(["path": finished.url.path, "title": finished.title])
        UserDefaults.standard.set(pending, forKey: DefaultsKeys.meetingNotesPending)
    }

    /// Ends both recordings and mixes them; nil when there is nothing worth keeping.
    private func finishRecording() async -> (url: URL, title: String)? {
        guard let session else { return nil }
        self.session = nil
        checkTimer?.invalidate()
        checkTimer = nil
        await MeetingLiveTranscript.shared.stop()
        let duration = await SystemAudioCaptureService.shared.stopCapture()
        microphone?.stop()
        microphone = nil
        ActivityTrail.mark("meeting notes stopped")

        guard duration >= Self.minLength else {
            for url in [session.url, session.microphoneURL].compactMap({ $0 }) {
                try? FileManager.default.removeItem(at: url)
            }
            logger.info("Meeting recording too short to keep")
            return nil
        }
        guard let microphoneURL = session.microphoneURL else { return (session.url, session.title) }
        let mixed = Self.directory.appendingPathComponent("meeting_\(UUID().uuidString)_mixed.wav")
        do {
            try MeetingAudioMixer.mix(session.url, microphoneURL, into: mixed)
            try? FileManager.default.removeItem(at: session.url)
            try? FileManager.default.removeItem(at: microphoneURL)
            return (mixed, session.title)
        } catch {
            // The call's own sound is still the meeting; better that than nothing.
            logger.error("Could not mix in the microphone: \(error, privacy: .public)")
            try? FileManager.default.removeItem(at: microphoneURL)
            return (session.url, session.title)
        }
    }

    // MARK: Writing up

    private func writeUp(_ url: URL, title: String) {
        guard let engine, let mode = ModeManager.shared.currentEffectiveConfiguration else {
            NotificationManager.shared.showNotification(
                title: String(localized: "The meeting was recorded but could not be transcribed: no mode is set up."),
                type: .warning)
            return
        }
        let manager = AudioTranscriptionManager.shared
        manager.addToQueue(
            urls: [url], prompt: Self.prompt(title: title), deletesSourceWhenDone: true,
            label: String(localized: "Meeting Notes"))
        manager.startProcessing(modelContext: engine.modelContext, engine: engine, mode: mode)
    }

    /// Recordings saved when VoxOS quit mid-meeting.
    private static func pendingMeetings() -> [[String: String]] {
        UserDefaults.standard.array(forKey: DefaultsKeys.meetingNotesPending) as? [[String: String]] ?? []
    }

    private func writeUpPendingMeetings() {
        let pending = Self.pendingMeetings()
        guard !pending.isEmpty else { return }
        UserDefaults.standard.removeObject(forKey: DefaultsKeys.meetingNotesPending)
        for meeting in pending {
            guard let path = meeting["path"], FileManager.default.fileExists(atPath: path) else { continue }
            logger.info("Writing up a meeting recorded before VoxOS quit")
            writeUp(URL(fileURLWithPath: path), title: meeting["title"] ?? String(localized: "Meeting Notes"))
        }
    }

    /// Asks for a summary, decisions and action items, followed by the transcript as heard.
    static func prompt(title: String) -> CustomPrompt {
        CustomPrompt(
            title: String(localized: "Meeting Notes"),
            promptText: """
                The transcript is a recording of a meeting called “\(title)”. Lines may start with \
                a speaker label such as "Speaker 1:". Write meeting notes in the transcript's language:

                Summary: three to five sentences on what the meeting was about and where it ended up.
                Decisions: a bulleted list of what was decided, or "None".
                Action items: a bulleted list of who does what, with any date mentioned, or "None".

                Use only what the transcript says. Do not invent names, dates or tasks.
                """,
            useSystemInstructions: false)
    }
}

/// Mixes the microphone into the call's recording: two 16 kHz mono files summed sample for
/// sample, read and written in chunks so an hour's meeting never sits in memory at once.
enum MeetingAudioMixer {
    enum MixError: Error { case formatsDiffer, noBuffer }

    /// Two runs of samples summed, the shorter padded with silence, clipped to full scale.
    static func mixed(_ first: [Float], _ second: [Float]) -> [Float] {
        (0..<max(first.count, second.count)).map { i in
            let sum = (i < first.count ? first[i] : 0) + (i < second.count ? second[i] : 0)
            return min(1, max(-1, sum))
        }
    }

    static let chunkFrames: AVAudioFrameCount = 16_000 * 10

    static func mix(_ first: URL, _ second: URL, into output: URL) throws {
        let a = try AVAudioFile(forReading: first, commonFormat: .pcmFormatFloat32, interleaved: false)
        let b = try AVAudioFile(forReading: second, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = a.processingFormat
        guard format.sampleRate == b.processingFormat.sampleRate,
            format.channelCount == 1, b.processingFormat.channelCount == 1
        else { throw MixError.formatsDiffer }
        let out = try AVAudioFile(
            forWriting: output, settings: a.fileFormat.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let bufferA = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames),
            let bufferB = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames)
        else { throw MixError.noBuffer }

        while a.framePosition < a.length || b.framePosition < b.length {
            bufferA.frameLength = 0
            bufferB.frameLength = 0
            if a.framePosition < a.length { try a.read(into: bufferA, frameCount: chunkFrames) }
            if b.framePosition < b.length { try b.read(into: bufferB, frameCount: chunkFrames) }
            let frames = max(bufferA.frameLength, bufferB.frameLength)
            guard frames > 0, let samplesA = bufferA.floatChannelData?[0], let samplesB = bufferB.floatChannelData?[0]
            else { break }
            for i in 0..<Int(frames) {
                let x = i < Int(bufferA.frameLength) ? samplesA[i] : 0
                let y = i < Int(bufferB.frameLength) ? samplesB[i] : 0
                samplesA[i] = min(1, max(-1, x + y))
            }
            bufferA.frameLength = frames
            try out.write(from: bufferA)
        }
    }
}
