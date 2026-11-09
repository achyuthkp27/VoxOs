import Foundation
import Testing

@testable import VoxOS

/// The recorder's logic that needs no microphone: which of an interface's channels are
/// recorded, and the levels the recording meter shows.
@Suite
struct CoreAudioRecorderTests {

    // MARK: - Input channels

    @Test func aStereoInterfaceRecordsItsFirstTwoChannels() {
        let selection = AudioInputChannelSelection.resolve(deviceChannelCount: 8, preferredStereoChannels: nil)
        #expect(selection.deviceChannelIndices == [0, 1])
    }

    @Test func aMonoMicrophoneRecordsItsOneChannel() {
        let selection = AudioInputChannelSelection.resolve(deviceChannelCount: 1, preferredStereoChannels: nil)
        #expect(selection.deviceChannelIndices == [0])
    }

    @Test func aDeviceWithNoChannelsRecordsNothing() {
        let selection = AudioInputChannelSelection.resolve(deviceChannelCount: 0, preferredStereoChannels: [1, 2])
        #expect(selection.deviceChannelIndices.isEmpty)
    }

    @Test func theDevicesPreferredPairIsUsedCountingFromZero() {
        // Core Audio numbers channels from 1; the recorder's indices start at 0.
        let selection = AudioInputChannelSelection.resolve(deviceChannelCount: 8, preferredStereoChannels: [3, 4])
        #expect(selection.deviceChannelIndices == [2, 3])
    }

    @Test func aPreferredChannelTheDeviceDoesNotHaveFallsBackToTheFirstTwo() {
        let selection = AudioInputChannelSelection.resolve(deviceChannelCount: 2, preferredStereoChannels: [1, 5])
        #expect(selection.deviceChannelIndices == [0, 1])
    }

    @Test func aChannelListedTwiceIsRecordedOnce() {
        let selection = AudioInputChannelSelection.resolve(deviceChannelCount: 4, preferredStereoChannels: [2, 2])
        #expect(selection.deviceChannelIndices == [1])
    }

    // MARK: - Meter

    private func levels(_ samples: [Float32]) -> (average: Float, peak: Float) {
        samples.withUnsafeBufferPointer { CoreAudioRecorder.meterLevels($0) }
    }

    @Test func silenceReadsAsTheFloorNotMinusInfinity() {
        let silent = levels([0, 0, 0, 0])
        #expect(silent.average == -120)
        #expect(silent.peak == -120)
        #expect(levels([]).average == -120)
    }

    @Test func fullScaleReadsAsZeroDecibels() {
        let full = levels([1, -1, 1, -1])
        #expect(abs(full.average) < 0.001)
        #expect(abs(full.peak) < 0.001)
    }

    @Test func halfScaleIsAboutSixDecibelsDown() {
        #expect(abs(levels([0.5, -0.5]).average - -6.0206) < 0.001)
    }

    @Test func aSingleSpikeRaisesThePeakMoreThanTheAverage() {
        let spiky = levels([0, 0, 0, 1])
        #expect(abs(spiky.peak) < 0.001)
        #expect(abs(spiky.average - -6.0206) < 0.001, "RMS of one full-scale sample in four is 0.5")
    }
}
