import Accelerate
import AudioToolbox
import CoreAudio
import Foundation
import os

/// What the Mac is playing, as bar levels for the notch's music bars, read from a Core Audio
/// process tap (macOS 14.2+).
///
/// A tap rather than the ScreenCaptureKit capture SystemAudioCaptureController uses: that one
/// records the display, holds the screen-recording indicator on for as long as it runs, and
/// downmixes to 16 kHz for transcription. The tap listens to output only, excluding VoxOS's own
/// sounds, and needs the "System Audio Recording Only" permission (NSAudioCaptureUsageDescription).
///
/// It is global rather than aimed at the player's process: browsers play through helper
/// processes, so a tap on Safari or Chrome itself would hear nothing.
final class SystemAudioLevels: @unchecked Sendable {
    static let shared = SystemAudioLevels()
    static let bandCount = SpectrumAnalyzer.bandEdges.count - 1

    /// Start, stop and restart run here; the tap's buffers arrive on `ioQueue`. Kept apart because
    /// AudioDeviceStop waits for the IO block to return.
    private let controlQueue = DispatchQueue(label: "com.achyuthkp.voxos.audio-levels.control")
    private let ioQueue = DispatchQueue(label: "com.achyuthkp.voxos.audio-levels.io", qos: .userInteractive)
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "SystemAudioLevels")

    private var latest = [Float](repeating: 0, count: bandCount)
    private var analyzer: SpectrumAnalyzer?
    private var mono: [Float] = []
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var wanted = false
    /// The tap's end, scheduled by a lingering stop; cancelled if the bars come back first.
    private var pendingTearDown: DispatchWorkItem?
    /// The first seconds after each start are logged (callbacks, loudest sample, levels), so a
    /// tap that delivers silence shows up in Console instead of as bars that just sit still.
    private var reportUntil = Date.distantPast
    private var nextReport = Date.distantPast
    private var callbacks = 0
    private var outputListener: AudioObjectPropertyListenerBlock?

    private init() {}

    /// The latest bar heights, 0…1; zeros while stopped.
    var levels: [Float] { lock.withLock { latest } }

    func start() {
        controlQueue.async { [self] in
            guard !wanted else { return }
            wanted = true
            if let pendingTearDown {
                // Still listening from a moment ago: that tap is kept rather than built again.
                pendingTearDown.cancel()
                self.pendingTearDown = nil
                if aggregateID != kAudioObjectUnknown { return }
                unwatchDefaultOutput()
            }
            build()
            watchDefaultOutput()
        }
    }

    /// With `linger`, the tap is kept that long first, so bars that hide and come straight back
    /// (the card opening over the band, a page swiped past) reuse it: building a tap and its
    /// aggregate device costs more than seconds of listening. Without, it goes at once, as when
    /// the setting is turned off and the recording dot should go with it.
    func stop(linger: TimeInterval = 0) {
        controlQueue.async { [self] in
            guard wanted || pendingTearDown != nil else { return }
            // Already winding down: a later call does not push the end back.
            if !wanted, linger > 0 { return }
            wanted = false
            pendingTearDown?.cancel()
            let work = DispatchWorkItem { [self] in
                pendingTearDown = nil
                unwatchDefaultOutput()
                tearDown()
            }
            if linger > 0 {
                pendingTearDown = work
                controlQueue.asyncAfter(deadline: .now() + linger, execute: work)
            } else {
                pendingTearDown = nil
                work.perform()
            }
        }
    }

    // MARK: Tap

    private func build() {
        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: Self.processObject(for: getpid()).map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "VoxOS notch music bars"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            return fail("tap not created", status)
        }
        tapID = tap

        guard let outputUID = Self.defaultOutputUID() else {
            tearDown()
            return fail("no default output device", 0)
        }
        let sampleRate = Self.sampleRate(ofTap: tap) ?? 48_000
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VoxOS notch music bars",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]
            ],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr, device != kAudioObjectUnknown else {
            tearDown()
            return fail("aggregate device not created", status)
        }
        aggregateID = device

        lock.withLock { analyzer = SpectrumAnalyzer(sampleRate: Float(sampleRate)) }
        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, ioQueue) { [weak self] _, input, _, _, _ in
            self?.consume(input)
        }
        guard status == noErr, let proc else {
            tearDown()
            return fail("IO proc not created", status)
        }
        procID = proc
        status = AudioDeviceStart(device, proc)
        guard status == noErr else {
            tearDown()
            return fail("device did not start", status)
        }
        logger.notice("Notch music bars listening at \(sampleRate, privacy: .public) Hz")
        ioQueue.async { [self] in
            reportUntil = Date().addingTimeInterval(10)
            nextReport = Date().addingTimeInterval(2)
            callbacks = 0
        }
    }

    private func tearDown() {
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        lock.withLock {
            analyzer = nil
            latest = [Float](repeating: 0, count: Self.bandCount)
        }
    }

    private func fail(_ what: String, _ status: OSStatus) {
        logger.error("Notch music bars: \(what, privacy: .public) (\(status, privacy: .public))")
    }

    /// Mixes whatever layout the tap delivers (interleaved or one buffer per channel) to mono.
    private func consume(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let firstData = first.mData else { return }
        let channels = Int(max(1, first.mNumberChannels))
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        guard frames > 0 else { return }
        if mono.count != frames { mono = [Float](repeating: 0, count: frames) }

        if buffers.count > 1 {
            let count = buffers.count
            for frame in 0..<frames { mono[frame] = 0 }
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frames { mono[frame] += samples[frame] / Float(count) }
            }
        } else {
            let samples = firstData.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += samples[frame * channels + channel] }
                mono[frame] = sum / Float(channels)
            }
        }

        let levels: [Float] = lock.withLock {
            analyzer?.feed(mono)
            if let analyzer { latest = analyzer.levels }
            return latest
        }

        callbacks += 1
        let now = Date()
        if now < reportUntil, now >= nextReport {
            var peak: Float = 0
            vDSP_maxmgv(mono, 1, &peak, vDSP_Length(frames))
            let shown = levels.map { String(format: "%.2f", $0) }.joined(separator: " ")
            logger.notice(
                "Notch music bars: \(self.callbacks, privacy: .public) callbacks, \(frames, privacy: .public) frames x \(channels, privacy: .public) ch in \(buffers.count, privacy: .public) buffers, peak \(peak, privacy: .public), levels \(shown, privacy: .public)"
            )
            nextReport = now.addingTimeInterval(2)
        }
    }

    // MARK: Output device

    /// The aggregate is clocked by the output it was built on; when the output changes (AirPods
    /// connect, a display's speakers), it is rebuilt on the new one.
    private func watchDefaultOutput() {
        var address = Self.defaultOutputAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.controlQueue.async {
                guard self.wanted else {
                    // A lingering tap on the old output is not worth keeping.
                    if let pending = self.pendingTearDown {
                        pending.cancel()
                        self.pendingTearDown = nil
                        self.unwatchDefaultOutput()
                        self.tearDown()
                    }
                    return
                }
                self.tearDown()
                self.build()
            }
        }
        outputListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, listener)
    }

    private func unwatchDefaultOutput() {
        guard let outputListener else { return }
        var address = Self.defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, controlQueue, outputListener)
        self.outputListener = nil
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    // MARK: Properties

    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputUID() -> String? {
        var address = defaultOutputAddress
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
                == noErr, device != kAudioObjectUnknown
        else { return nil }
        address.mSelector = kAudioDevicePropertyDeviceUID
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }

    private static func sampleRate(ofTap tap: AudioObjectID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr, format.mSampleRate > 0
        else { return nil }
        return format.mSampleRate
    }
}
