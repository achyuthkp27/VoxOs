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
    }
}
