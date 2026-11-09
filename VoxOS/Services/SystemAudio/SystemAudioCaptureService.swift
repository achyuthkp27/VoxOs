import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import os

/// Captures what the Mac is *playing* — the far side of a call, a video, a podcast — and
/// never the microphone. Output matches what `CoreAudioRecorder` produces (16 kHz mono
/// PCM) so the existing transcription services can consume it unchanged.
///
/// It listens through a Core Audio process tap on the system output, like the notch's music
/// bars, so it needs only the System Audio Recording permission: nothing of the screen is
/// captured. VoxOS's own sounds are left out of the tap.
///
/// Three uses share one tap:
/// - **Capture**: writes everything between `startCapture` and `stopCapture` to a WAV file.
/// - **Buffering**: keeps only the most recent N seconds in memory, so a shortcut can ask
///   "what was just said?" after the fact without keeping any of it on disk.
/// - **Live**: hands out what arrived since the last ask, for a meeting's live transcript.
final class SystemAudioCaptureService: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case permissionDenied
        case noOutputDevice
        case formatUnavailable
        case notBuffering
        case bufferEmpty

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return String(localized: "VoxOS needs System Audio Recording permission to capture system audio.")
            case .noOutputDevice:
                return String(localized: "No sound output is available to capture system audio from.")
            case .formatUnavailable:
                return String(localized: "The system audio format could not be read.")
            case .notBuffering:
                return String(localized: "System audio buffering is not running.")
            case .bufferEmpty:
                return String(localized: "No system audio has been captured yet.")
            }
        }
    }

    static let shared = SystemAudioCaptureService()

    /// Transcription services expect 16 kHz mono; matches `CoreAudioRecorder`'s output.
    static let outputSampleRate: Double = 16000
    /// Hard ceiling on the rolling buffer so memory stays bounded (~2 MB/min at 16 kHz float).
    static let maximumBufferSeconds: Double = 300
    /// The live samples kept when nobody asks for them, so a stalled reader cannot grow memory.
    static let maximumLiveSeconds: Double = 120

    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "SystemAudioCapture")
    /// Building and destroying the tap run here; its buffers arrive on `ioQueue`. Kept apart
    /// because AudioDeviceStop waits for the IO block to return.
    private let controlQueue = DispatchQueue(label: "com.achyuthkp.voxos.systemaudio.control")
    private let ioQueue = DispatchQueue(label: "com.achyuthkp.voxos.systemaudio.io", qos: .userInitiated)
    private let stateLock = NSLock()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var outputListener: AudioObjectPropertyListenerBlock?
    /// Fired when the tap dies underneath us and cannot be rebuilt (no output device left).
    var onStreamStopped: (@Sendable () -> Void)?

    private var tapFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var mono: [Float] = []

    private var audioFile: AVAudioFile?
    private var isWritingToFile = false

    private var ringBuffer: [Float] = []
    private var ringWriteIndex = 0
    private var ringFilled = false
    private var ringCapacity = 0
    private var isBuffering = false

    private var isCollectingLive = false
    private var liveSamples: [Float] = []

    /// All state access goes through here; the closure is synchronous, so no lock is ever
    /// held across an `await`.
    private func withState<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private lazy var outputFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.outputSampleRate,
            channels: 1,
            interleaved: false
        )!
    }()

    private init() {}

    // MARK: - Permission

    /// macOS has no way to ask ahead whether System Audio Recording is allowed: it asks the user
    /// the first time a tap starts, and a denied tap delivers silence rather than failing.
    static func hasPermission() -> Bool { true }

    @discardableResult
    static func requestPermission() async -> Bool { true }

    // MARK: - Public state

    var isCapturingToFile: Bool { withState { isWritingToFile } }

    var isBufferingRecentAudio: Bool { withState { isBuffering } }

    /// Seconds of audio currently held in the rolling buffer.
    var bufferedSeconds: Double {
        withState {
            let frames = ringFilled ? ringCapacity : ringWriteIndex
            return Double(frames) / Self.outputSampleRate
        }
    }

    // MARK: - Capture to file

    /// Records system audio to `url` (16 kHz mono WAV) until `stopCapture()` is called.
    func startCapture(to url: URL) async throws {
        try ensureTapRunning()

        let file: AVAudioFile
        do {
            file = try AVAudioFile(forWriting: url, settings: Self.fileSettings)
        } catch {
            // Otherwise the tap keeps running with nothing consuming it.
            if !withState({ isBuffering || isCollectingLive }) { tearDownTap() }
            throw error
        }

        withState {
            audioFile = file
            isWritingToFile = true
        }

        logger.info("Started system audio capture to \(url.lastPathComponent, privacy: .public)")
    }

    /// Stops writing and returns how many seconds were captured.
    @discardableResult
    func stopCapture() async -> Double {
        let (frames, stillNeeded): (AVAudioFramePosition, Bool) = withState {
            let frames = audioFile?.length ?? 0
            audioFile = nil
            isWritingToFile = false
            return (frames, isBuffering || isCollectingLive)
        }

        if !stillNeeded { tearDownTap() }

        let seconds = Double(frames) / Self.outputSampleRate
        logger.info("Stopped system audio capture (\(String(format: "%.1f", seconds), privacy: .public)s)")
        return seconds
    }

    // MARK: - Live

    /// Starts keeping what arrives for `takeLiveSamples()`. Runs alongside a capture.
    func startLive() throws {
        try ensureTapRunning()
        withState {
            liveSamples = []
            isCollectingLive = true
        }
    }

    func stopLive() {
        let stillNeeded: Bool = withState {
            isCollectingLive = false
            liveSamples = []
            return isWritingToFile || isBuffering
        }
        if !stillNeeded { tearDownTap() }
    }

    /// The 16 kHz mono samples that arrived since the last call.
    func takeLiveSamples() -> [Float] {
        withState {
            let taken = liveSamples
            liveSamples = []
            return taken
        }
    }

    // MARK: - Rolling buffer

    /// Starts keeping the most recent `seconds` of system audio in memory.
    func startBuffering(seconds: Double) async throws {
        let clamped = min(max(seconds, 5), Self.maximumBufferSeconds)
        try ensureTapRunning()

        withState {
            ringCapacity = Int(clamped * Self.outputSampleRate)
            ringBuffer = [Float](repeating: 0, count: ringCapacity)
            ringWriteIndex = 0
            ringFilled = false
            isBuffering = true
        }

        logger.info("Started system audio buffering (\(Int(clamped), privacy: .public)s window)")
    }

    func stopBuffering() async {
        let stillNeeded: Bool = withState {
            isBuffering = false
            ringBuffer = []
            ringCapacity = 0
            ringWriteIndex = 0
            ringFilled = false
            return isWritingToFile || isCollectingLive
        }

        if !stillNeeded { tearDownTap() }
        logger.info("Stopped system audio buffering")
    }

    /// Writes the most recent `seconds` of buffered audio to `url` as 16 kHz mono WAV.
    /// Returns the duration actually written, which is shorter when the buffer is not yet full.
    @discardableResult
    func writeRecentAudio(seconds: Double, to url: URL) throws -> Double {
        stateLock.lock()
        guard isBuffering, ringCapacity > 0 else {
            stateLock.unlock()
            throw CaptureError.notBuffering
        }
        let samples = orderedBufferedSamples(limitedTo: seconds)
        stateLock.unlock()

        guard !samples.isEmpty else { throw CaptureError.bufferEmpty }
        try Self.write(samples, to: url, format: outputFormat)
        return Double(samples.count) / Self.outputSampleRate
    }

    /// Writes 16 kHz mono `samples` to `url` as a WAV file.
    static func write(_ samples: [Float], to url: URL, format: AVAudioFormat? = nil) throws {
        guard
            let format = format
                ?? AVAudioFormat(
                    commonFormat: .pcmFormatFloat32, sampleRate: outputSampleRate, channels: 1, interleaved: false),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { throw CaptureError.formatUnavailable }
        let file = try AVAudioFile(forWriting: url, settings: fileSettings)
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress!, count: samples.count)
            }
        }
        try file.write(from: buffer)
    }

    static let fileSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: outputSampleRate,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    /// Caller must hold `stateLock`.
    private func orderedBufferedSamples(limitedTo seconds: Double) -> [Float] {
        let available = ringFilled ? ringCapacity : ringWriteIndex
        guard available > 0 else { return [] }

        let requested = min(available, Int(seconds * Self.outputSampleRate))
        guard requested > 0 else { return [] }

        var ordered = [Float]()
        ordered.reserveCapacity(requested)
        // Walk backwards from the write head so the newest `requested` frames come out in order.
        let start = ((ringWriteIndex - requested) % ringCapacity + ringCapacity) % ringCapacity
        for offset in 0..<requested {
            ordered.append(ringBuffer[(start + offset) % ringCapacity])
        }
        return ordered
    }

    // MARK: - Tap lifecycle

    private func ensureTapRunning() throws {
        var failure: CaptureError?
        controlQueue.sync {
            guard aggregateID == kAudioObjectUnknown else { return }
            failure = buildTap()
            if failure == nil { watchDefaultOutput() }
        }
        if let failure { throw failure }
    }

    private func tearDownTap() {
        controlQueue.sync {
            unwatchDefaultOutput()
            destroyTap()
        }
        logger.info("System audio tap stopped")
    }

    /// Runs on `controlQueue`. A global tap on the output, without VoxOS, read through a private
    /// aggregate device clocked by the current output.
    private func buildTap() -> CaptureError? {
        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: SystemAudioLevels.processObject(for: getpid()).map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "VoxOS system audio capture"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            logger.error("System audio tap not created (\(status, privacy: .public))")
            return .permissionDenied
        }
        tapID = tap

        guard let outputUID = Self.defaultOutputUID() else {
            destroyTap()
            return .noOutputDevice
        }
        guard let format = Self.format(ofTap: tap) else {
            destroyTap()
            return .formatUnavailable
        }
        withState {
            tapFormat = format
            converter = nil
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VoxOS system audio capture",
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
            destroyTap()
            logger.error("System audio aggregate device not created (\(status, privacy: .public))")
            return .formatUnavailable
        }
        aggregateID = device

        var proc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, ioQueue) { [weak self] _, input, _, _, _ in
            self?.consume(input)
        }
        guard status == noErr, let proc else {
            destroyTap()
            return .formatUnavailable
        }
        procID = proc
        status = AudioDeviceStart(device, proc)
        guard status == noErr else {
            destroyTap()
            return .formatUnavailable
        }
        logger.info("System audio tap listening at \(format.sampleRate, privacy: .public) Hz")
        return nil
    }

    /// Runs on `controlQueue`.
    private func destroyTap() {
        if aggregateID != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        withState { converter = nil }
    }

    /// The aggregate is clocked by the output it was built on; when the output changes
    /// (AirPods connect, a display's speakers), the tap is rebuilt on the new one, and the
    /// capture, buffer and live samples carry on.
    private func watchDefaultOutput() {
        var address = Self.defaultOutputAddress
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.controlQueue.async {
                guard self.aggregateID != kAudioObjectUnknown else { return }
                self.destroyTap()
                if self.buildTap() != nil {
                    self.unwatchDefaultOutput()
                    self.withState {
                        self.audioFile = nil
                        self.isWritingToFile = false
                        self.isBuffering = false
                        self.isCollectingLive = false
                    }
                    self.onStreamStopped?()
                }
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

    // MARK: - Sample handling

    /// Mixes whatever layout the tap delivers to mono, converts it to 16 kHz, and hands it to
    /// the file, the rolling buffer and the live samples.
    private func consume(_ input: UnsafePointer<AudioBufferList>) {
        guard withState({ isWritingToFile || isBuffering || isCollectingLive }) else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let firstData = first.mData else { return }
        let channels = Int(max(1, first.mNumberChannels))
        let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
        guard frames > 0 else { return }
        if mono.count != frames { mono = [Float](repeating: 0, count: frames) }
        if buffers.count > 1 {
            for frame in 0..<frames { mono[frame] = 0 }
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                for frame in 0..<frames { mono[frame] += samples[frame] / Float(buffers.count) }
            }
        } else {
            let samples = firstData.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += samples[frame * channels + channel] }
                mono[frame] = sum / Float(channels)
            }
        }

        guard
            let pair = withState({ () -> (AVAudioConverter, AVAudioFormat)? in
                guard let tapFormat else { return nil }
                if converter == nil { converter = AVAudioConverter(from: tapFormat, to: outputFormat) }
                return converter.map { ($0, tapFormat) }
            }),
            case (let audioConverter, let inputFormat) = pair,
            let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(frames)),
            let inputChannel = inputBuffer.floatChannelData?[0]
        else { return }
        inputBuffer.frameLength = AVAudioFrameCount(frames)
        mono.withUnsafeBufferPointer { inputChannel.update(from: $0.baseAddress!, count: frames) }

        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var suppliedInput = false
        var conversionError: NSError?
        audioConverter.convert(to: outputBuffer, error: &conversionError) { _, statusPointer in
            if suppliedInput {
                statusPointer.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            statusPointer.pointee = .haveData
            return inputBuffer
        }
        if let conversionError {
            logger.error("System audio conversion failed: \(conversionError.localizedDescription, privacy: .public)")
            return
        }
        guard outputBuffer.frameLength > 0, let channel = outputBuffer.floatChannelData?[0] else { return }
        let converted = UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength))

        stateLock.lock()
        if isBuffering { appendToRing(converted) }
        if isCollectingLive {
            liveSamples.append(contentsOf: converted)
            let limit = Int(Self.maximumLiveSeconds * Self.outputSampleRate)
            if liveSamples.count > limit { liveSamples.removeFirst(liveSamples.count - limit) }
        }
        // Written under the lock: AVAudioFile is not thread-safe, and stopCapture() reads
        // `length` and drops the file under this same lock. This runs on `ioQueue`, a dispatch
        // queue rather than the real-time thread, so holding the lock across the write is fine.
        if isWritingToFile, let file = audioFile {
            do {
                try file.write(from: outputBuffer)
            } catch {
                logger.error("Failed writing system audio: \(error.localizedDescription, privacy: .public)")
            }
        }
        stateLock.unlock()
    }

    /// Caller must hold `stateLock`.
    private func appendToRing(_ samples: UnsafeBufferPointer<Float>) {
        guard ringCapacity > 0 else { return }
        for sample in samples {
            ringBuffer[ringWriteIndex] = sample
            ringWriteIndex += 1
            if ringWriteIndex == ringCapacity {
                ringWriteIndex = 0
                ringFilled = true
            }
        }
    }

    // MARK: - Core Audio properties

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
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

    /// The tap's sample rate, as the mono float format the IO block's downmix produces.
    private static func format(ofTap tap: AudioObjectID) -> AVAudioFormat? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let rate =
            AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &description) == noErr
                && description.mSampleRate > 0 ? description.mSampleRate : 48_000
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)
    }
}
