import AppKit
import Foundation
import os

/// Notes for a call joined from VoxOS: the call's sound is recorded while it lasts, then
/// transcribed with who spoke, summarized with action items, and saved to History.
///
/// Only what the Mac plays is recorded, so the other people in the call, never the microphone.
/// It starts when Join is clicked in the notch or on the Calendar page with Meeting Notes on,
/// and stops at the meeting's end, or later while the call app still has the microphone, or
/// from the menu bar.
@MainActor
final class MeetingNotes: ObservableObject {
    static let shared = MeetingNotes()

    struct Session: Equatable {
        let title: String
        let startedAt: Date
        let scheduledEnd: Date
        let url: URL
    }

    @Published private(set) var session: Session?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.meetingNotesEnabled) }

    /// How long past its scheduled end a call is followed while it still has the microphone.
    nonisolated static let maxOverrun: TimeInterval = 60 * 60
    /// The longest a recording runs, whatever the calendar says.
    nonisolated static let maxLength: TimeInterval = 4 * 60 * 60
    /// Shorter than this is a call that never happened; nothing is saved.
    nonisolated static let minLength: TimeInterval = 30

    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "MeetingNotes")
    private weak var engine: VoxOSEngine?
    private var checkTimer: Timer?

    private init() {}

    func configure(engine: VoxOSEngine) {
        self.engine = engine
    }

    /// Called when the user joins a call from VoxOS.
    func joined(title: String, end: Date) {
        guard Self.isEnabled, session == nil, !ProcessIdentity.isTestHost else { return }
        guard !SystemAudioCaptureController.shared.isCapturing else {
            NotificationManager.shared.showNotification(
                title: String(localized: "Meeting notes did not start: system audio is already being captured."),
                type: .warning)
            return
        }
        Task { await start(title: title, end: end) }
    }

    private func start(title: String, end: Date) async {
        // A temporary file: Transcribe Audio saves its own copy beside the transcript, then deletes this.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "voxos-meeting-\(UUID().uuidString).wav")
        do {
            try await SystemAudioCaptureService.shared.startCapture(to: url)
        } catch {
            logger.error("Meeting notes could not start: \(error, privacy: .public)")
            NotificationManager.shared.showNotification(
                title: String(localized: "Meeting notes need System Audio Recording, in System Settings → Privacy."),
                type: .warning)
            return
        }
        let now = Date()
        session = Session(title: title, startedAt: now, scheduledEnd: max(end, now), url: url)
        ActivityTrail.mark("meeting notes started")
        NotificationManager.shared.showNotification(
            title: String(localized: "Taking notes on “\(title)”: recording the call’s sound, not your microphone."),
            type: .info, duration: 4)
        let timer = Timer(timeInterval: 60, repeats: true) { _ in
            Task { @MainActor in MeetingNotes.shared.check() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        checkTimer = timer
    }

    /// Stops when the meeting is over: past its end and the call has let go of the microphone.
    private func check(now: Date = Date()) {
        guard let session else { return }
        let callStillOn = NotchPrivacy.isEnabled ? NotchPrivacy.shared.state.microphone : nil
        if !Self.shouldKeepRecording(session: session, now: now, callStillOn: callStillOn) {
            Task { await stop() }
        }
    }

    /// Whether a recording carries on: until its scheduled end; after it, only while the call
    /// app still has the microphone (unknown counts as no) and for at most `maxOverrun`; never
    /// past `maxLength`.
    nonisolated static func shouldKeepRecording(session: Session, now: Date, callStillOn: Bool?) -> Bool {
        if now.timeIntervalSince(session.startedAt) >= maxLength { return false }
        if now < session.scheduledEnd { return true }
        return callStillOn == true && now.timeIntervalSince(session.scheduledEnd) < maxOverrun
    }

    /// Stops recording and hands the call to Transcribe Audio with the meeting notes prompt.
    func stop() async {
        guard let session else { return }
        self.session = nil
        checkTimer?.invalidate()
        checkTimer = nil
        let duration = await SystemAudioCaptureService.shared.stopCapture()
        ActivityTrail.mark("meeting notes stopped")

        guard duration >= Self.minLength else {
            try? FileManager.default.removeItem(at: session.url)
            logger.info("Meeting recording too short to keep")
            return
        }
        guard let engine, let mode = ModeManager.shared.currentEffectiveConfiguration else {
            NotificationManager.shared.showNotification(
                title: String(localized: "The meeting was recorded but could not be transcribed: no mode is set up."),
                type: .warning)
            return
        }
        let manager = AudioTranscriptionManager.shared
        manager.addToQueue(urls: [session.url], prompt: Self.prompt(title: session.title), deletesSourceWhenDone: true)
        manager.startProcessing(modelContext: engine.modelContext, engine: engine, mode: mode)
        NotificationManager.shared.showNotification(
            title: String(localized: "Writing up “\(session.title)”. It will be in History when done."),
            type: .info, duration: 4)
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
