import AVFoundation
import Foundation
import Testing

@testable import VoxOS

/// When a meeting's recording stops, what its notes ask the model for, and how long a long
/// transcript may take.
@MainActor
@Suite
struct MeetingNotesTests {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func session(minutes: Double) -> MeetingNotes.Session {
        MeetingNotes.Session(
            title: "Standup", startedAt: start, scheduledEnd: start.addingTimeInterval(minutes * 60),
            url: URL(fileURLWithPath: "/tmp/meeting.wav"))
    }

    private func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    @Test func itRecordsUntilTheScheduledEnd() {
        #expect(MeetingNotes.shouldKeepRecording(session: session(minutes: 30), now: at(29), callStillOn: false))
    }

    @Test func itStopsAtTheEndWhenTheCallHasLetGoOfTheMicrophone() {
        #expect(!MeetingNotes.shouldKeepRecording(session: session(minutes: 30), now: at(30), callStillOn: false))
    }

    @Test func itStopsAtTheEndWhenItCannotTellWhetherTheCallGoesOn() {
        #expect(!MeetingNotes.shouldKeepRecording(session: session(minutes: 30), now: at(31), callStillOn: nil))
    }

    @Test func aCallRunningOverIsFollowedForUpToAnHour() {
        #expect(MeetingNotes.shouldKeepRecording(session: session(minutes: 30), now: at(75), callStillOn: true))
        #expect(!MeetingNotes.shouldKeepRecording(session: session(minutes: 30), now: at(91), callStillOn: true))
    }

    @Test func noRecordingRunsPastFourHours() {
        #expect(!MeetingNotes.shouldKeepRecording(session: session(minutes: 600), now: at(240), callStillOn: true))
    }

    @Test func bothSidesAreRecordedUntilTheMicrophoneIsSwitchedOff() {
        let name = "MeetingNotesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(MeetingNotes.includesMicrophone(in: defaults), "a meeting has two sides")
        defaults.set(false, forKey: DefaultsKeys.meetingNotesIncludeMicrophone)
        #expect(!MeetingNotes.includesMicrophone(in: defaults))
    }

    @Test func aMeetingStartedByHandRunsUntilStopped() {
        var byHand = session(minutes: 0)
        byHand.endsByHand = true
        #expect(MeetingNotes.shouldKeepRecording(session: byHand, now: at(90), callStillOn: false))
        #expect(!MeetingNotes.shouldKeepRecording(session: byHand, now: at(240), callStillOn: true))
    }

    @Test func thePromptNamesTheMeetingAndAsksForActionItems() {
        let prompt = MeetingNotes.prompt(title: "Quarterly planning")
        #expect(prompt.promptText.contains("Quarterly planning"))
        #expect(prompt.promptText.contains("Action items"))
        #expect(prompt.promptText.contains("Do not invent"))
    }

    // MARK: - Timeout

    @Test func aDictationKeepsTheUsersTimeout() {
        #expect(AIEnhancementService.requestTimeout(base: 7, isAgentConversation: false, wordCount: 40) == 7)
    }

    @Test func theAgentsOpeningTurnGetsAtLeast45Seconds() {
        #expect(AIEnhancementService.requestTimeout(base: 7, isAgentConversation: true, wordCount: 10) == 45)
    }

    @Test func aLongTranscriptGetsLongerUpToThreeMinutes() {
        #expect(AIEnhancementService.requestTimeout(base: 7, isAgentConversation: false, wordCount: 1500) == 30)
        #expect(AIEnhancementService.requestTimeout(base: 7, isAgentConversation: false, wordCount: 50_000) == 180)
        #expect(AIEnhancementService.requestTimeout(base: 60, isAgentConversation: false, wordCount: 1500) == 60)
    }

    // MARK: - Queue

    @Test func aQueuedFileUsesTheModesPromptUnlessGivenOne() {
        let plain = AudioFileQueueItem(url: URL(fileURLWithPath: "/tmp/a.wav"))
        #expect(plain.prompt == nil)
        #expect(!plain.deletesSourceWhenDone)
        let meeting = AudioFileQueueItem(
            url: URL(fileURLWithPath: "/tmp/b.wav"), prompt: MeetingNotes.prompt(title: "x"),
            deletesSourceWhenDone: true)
        #expect(meeting.prompt?.title == String(localized: "Meeting Notes"))
        #expect(meeting.deletesSourceWhenDone)
        #expect(plain.label == nil, "an imported file keeps its mode's name in History")
        let labelled = AudioFileQueueItem(url: URL(fileURLWithPath: "/tmp/c.wav"), label: "Meeting Notes")
        #expect(labelled.label == "Meeting Notes")
    }

    // MARK: - Mixing in the microphone

    private func wav(_ samples: [Float], name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000.0, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (i, sample) in samples.enumerated() { buffer.floatChannelData![0][i] = sample }
        try file.write(from: buffer)
        return url
    }

    private func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return (0..<Int(buffer.frameLength)).map { buffer.floatChannelData![0][$0] }
    }

    @Test func theMicrophoneIsAddedToTheCallSampleForSample() throws {
        let call = try wav([0.1, 0.2, -0.3, 0.4], name: "call")
        let microphone = try wav([0.25, -0.25], name: "mic")
        let mixed = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-\(UUID().uuidString).wav")
        defer { [call, microphone, mixed].forEach { try? FileManager.default.removeItem(at: $0) } }

        try MeetingAudioMixer.mix(call, microphone, into: mixed)

        let result = try samples(mixed)
        #expect(result.count == 4, "as long as the longer recording")
        for (got, want) in zip(result, [Float(0.35), -0.05, -0.3, 0.4]) {
            #expect(abs(got - want) < 0.001)
        }
    }

    @Test func aLoudSumIsClippedRatherThanWrapped() throws {
        let call = try wav([0.9], name: "call")
        let microphone = try wav([0.9], name: "mic")
        let mixed = FileManager.default.temporaryDirectory.appendingPathComponent("mixed-\(UUID().uuidString).wav")
        defer { [call, microphone, mixed].forEach { try? FileManager.default.removeItem(at: $0) } }

        try MeetingAudioMixer.mix(call, microphone, into: mixed)

        #expect(try samples(mixed).first.map { $0 > 0.99 } == true)
    }
}
