import Foundation
import Testing

@testable import VoxOS

/// The live transcript's chunks: how the call and the microphone are combined, which chunks
/// are worth sending to a speech model, and the window's clock.
@Suite
struct MeetingLiveTranscriptTests {

    @Test func theCallAndTheMicrophoneAreAddedTogether() {
        #expect(MeetingAudioMixer.mixed([0.1, 0.2, 0.3], [0.5]) == [0.6, 0.2, 0.3])
        #expect(MeetingAudioMixer.mixed([], [0.25, -0.25]) == [0.25, -0.25])
    }

    @Test func aLoudSumIsClipped() {
        #expect(MeetingAudioMixer.mixed([0.8, -0.8], [0.8, -0.8]) == [1, -1])
    }

    @Test func silenceIsNotSentToTheModel() {
        let second = Int(SystemAudioCaptureService.outputSampleRate)
        #expect(!MeetingLiveTranscript.isWorthTranscribing([Float](repeating: 0, count: second * 2)))
        #expect(!MeetingLiveTranscript.isWorthTranscribing([Float](repeating: 0.0005, count: second * 2)))
    }

    @Test func speechLevelAudioIsSent() {
        let second = Int(SystemAudioCaptureService.outputSampleRate)
        let speech = (0..<(second * 2)).map { Float(sin(Double($0) / 8)) * 0.2 }
        #expect(MeetingLiveTranscript.isWorthTranscribing(speech))
    }

    @Test func lessThanASecondIsNotSent() {
        #expect(!MeetingLiveTranscript.isWorthTranscribing([Float](repeating: 0.3, count: 8000)))
    }

    @MainActor
    @Test func theClockShowsMinutesThenHours() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(MeetingTranscriptView.elapsed(from: start, to: start.addingTimeInterval(65)) == "1:05")
        #expect(MeetingTranscriptView.elapsed(from: start, to: start.addingTimeInterval(3_725)) == "1:02:05")
        #expect(MeetingTranscriptView.elapsed(from: start, to: start.addingTimeInterval(-5)) == "0:00")
    }
}
