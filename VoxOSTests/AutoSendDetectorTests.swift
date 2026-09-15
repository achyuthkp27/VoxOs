import Foundation
import Testing

@testable import VoxOS

/// Level traces at the recorder's real scale (-60…0 dB → 0…1), sampled every 100 ms.
struct AutoSendDetectorTests {

    /// Runs a trace of (level, transcript) samples; returns the time of the first non-listening decision.
    private func run(
        pause: TimeInterval = 1.5, _ samples: [(Double, String)]
    ) -> (decision: AutoSendDetector.Decision, at: TimeInterval)? {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var detector = AutoSendDetector(pause: pause, startedAt: start)
        for (index, sample) in samples.enumerated() {
            let t = Double(index + 1) * 0.1
            let decision = detector.feed(level: sample.0, transcript: sample.1, at: start.addingTimeInterval(t))
            if decision != .keepListening { return (decision, t) }
        }
        return nil
    }

    private func repeated(_ level: Double, _ seconds: Double, _ text: String = "") -> [(Double, String)] {
        Array(repeating: (level, text), count: Int((seconds * 10).rounded()))
    }

    @Test func quietRoomSendsAfterThePause() {
        // Room noise ≈ -45 dB (0.25) was above the old fixed 0.10 threshold, so this never sent.
        let trace = repeated(0.25, 0.5) + repeated(0.62, 1.2) + repeated(0.26, 3)
        let result = run(trace)
        #expect(result?.decision == .send)
        // Speech ends at 1.7s; send at ≈1.7 + 1.5.
        #expect(result.map { abs($0.at - 3.2) <= 0.15 } == true, "sent at \(String(describing: result?.at))")
    }

    @Test func shortPausesBetweenWordsDoNotSend() {
        let words = repeated(0.6, 0.6) + repeated(0.27, 0.7) + repeated(0.6, 0.6) + repeated(0.27, 0.9) + repeated(0.6, 0.5)
        let trace = repeated(0.25, 0.4) + words + repeated(0.26, 2.5)
        let result = run(trace)
        #expect(result?.decision == .send)
        #expect((result?.at ?? 0) > 4.0, "must wait for the final pause, not a gap between words")
    }

    @Test func talkingStraightAwayStillCalibrates() {
        // Speech starts before calibration ends; gaps between words pull the floor down.
        let trace = repeated(0.6, 0.8) + repeated(0.3, 0.3) + repeated(0.62, 0.8) + repeated(0.28, 3)
        #expect(run(trace)?.decision == .send)
    }

    @Test func noisyRoomFallsBackToASettledTranscript() {
        // TV in the background keeps levels high; the transcript stops changing.
        var trace = repeated(0.55, 0.4)
        trace += repeated(0.75, 0.5, "open")
        trace += repeated(0.75, 0.5, "open safari")
        trace += repeated(0.58, 6, "open safari")
        let result = run(trace)
        #expect(result?.decision == .send)
    }

    @Test func silenceGivesUp() {
        #expect(run(repeated(0.2, 13))?.decision == .giveUp)
    }

    @Test func pauseSettingChangesTiming() {
        let trace = repeated(0.25, 0.5) + repeated(0.62, 1.0) + repeated(0.25, 4)
        let quick = run(pause: 1.0, trace)?.at ?? 0
        let relaxed = run(pause: 2.2, trace)?.at ?? 0
        #expect(relaxed - quick >= 1.1)
    }

    @Test func aCoughIsNotARequest() {
        let trace = repeated(0.25, 0.5) + repeated(0.7, 0.2) + repeated(0.25, 11.5)
        #expect(run(trace)?.decision == .giveUp, "0.2s of noise is below minimum speech")
    }

    /// Recorded on this Mac: the meter reads 0 for the first samples, the room sits at ≈0.40,
    /// and a spoken "what time is it" peaks at 0.76–0.87 with the transcript arriving ~1s late.
    @Test func realTraceWithMeterWarmUp() {
        var trace = repeated(0.0, 0.2) + repeated(0.41, 1.8)
        trace += repeated(0.87, 0.5) + repeated(0.76, 0.6)
        trace += repeated(0.39, 0.5)
        trace += repeated(0.42, 4, "What time is it?")
        let result = run(trace)
        #expect(result?.decision == .send)
        // Speech ends at 3.1s; expect a send about one pause later, not after the transcript fallback.
        #expect(result.map { $0.at >= 4.4 && $0.at <= 5.0 } == true, "sent at \(String(describing: result?.at))")
    }
}
