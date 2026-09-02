import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit
import os

/// Captures what the Mac is *playing* — the far side of a call, a video, a podcast — and
/// never the microphone. Output matches what `CoreAudioRecorder` produces (16 kHz mono
/// PCM) so the existing transcription services can consume it unchanged.
///
/// Two modes share one stream:
/// - **Capture**: writes everything between `startCapture` and `stopCapture` to a WAV file.
/// - **Buffering**: keeps only the most recent N seconds in memory, so a shortcut can ask
///   "what was just said?" after the fact without keeping any of it on disk.
final class SystemAudioCaptureService: NSObject, @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case permissionDenied
        case noDisplayAvailable
        case formatUnavailable
        case notBuffering
        case bufferEmpty

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                return String(localized: "VoxOS needs Screen Recording permission to capture system audio.")
            case .noDisplayAvailable:
                return String(localized: "No display is available to capture system audio from.")
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

    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "SystemAudioCapture")
    private let sampleQueue = DispatchQueue(label: "com.achyuthkp.voxos.systemaudio.samples")
    private let stateLock = NSLock()

    private var stream: SCStream?
    private var isStartingStream = false
    /// Fired when the stream dies underneath us (display change, permission revoked).
    var onStreamStopped: (@Sendable () -> Void)?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    private var audioFile: AVAudioFile?
    private var isWritingToFile = false

    private var ringBuffer: [Float] = []
    private var ringWriteIndex = 0
    private var ringFilled = false
    private var ringCapacity = 0
    private var isBuffering = false

    private lazy var outputFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.outputSampleRate,
            channels: 1,
            interleaved: false
        )!
    }()

    private override init() {
        super.init()
    }

    // MARK: - Permission

    /// Screen Recording permission gates system-audio capture, exactly as it gates screen capture.
    static func hasPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestPermission() async -> Bool {
        await ScreenCaptureService.requestScreenCapturePermissionRegistration()
    }

    // MARK: - Public state

    var isCapturingToFile: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isWritingToFile
    }

    var isBufferingRecentAudio: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isBuffering
    }

    /// Seconds of audio currently held in the rolling buffer.
    var bufferedSeconds: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        let frames = ringFilled ? ringCapacity : ringWriteIndex
        return Double(frames) / Self.outputSampleRate
    }

    // MARK: - Capture to file

    /// Records system audio to `url` (16 kHz mono WAV) until `stopCapture()` is called.
    func startCapture(to url: URL) async throws {
        try await ensureStreamRunning()

        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.outputSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )

        stateLock.lock()
        audioFile = file
        isWritingToFile = true
        stateLock.unlock()

        logger.info("Started system audio capture to \(url.lastPathComponent, privacy: .public)")
    }

    /// Stops writing and returns how many seconds were captured.
    @discardableResult
    func stopCapture() async -> Double {
        stateLock.lock()
        let file = audioFile
        let frames = file?.length ?? 0
        audioFile = nil
        isWritingToFile = false
        let stillNeeded = isBuffering
        stateLock.unlock()

        if !stillNeeded {
            await teardownStream()
        }

        let seconds = Double(frames) / Self.outputSampleRate
        logger.info("Stopped system audio capture (\(String(format: "%.1f", seconds), privacy: .public)s)")
        return seconds
    }

    // MARK: - Rolling buffer

    /// Starts keeping the most recent `seconds` of system audio in memory.
    func startBuffering(seconds: Double) async throws {
        let clamped = min(max(seconds, 5), Self.maximumBufferSeconds)
        try await ensureStreamRunning()

        stateLock.lock()
        ringCapacity = Int(clamped * Self.outputSampleRate)
        ringBuffer = [Float](repeating: 0, count: ringCapacity)
        ringWriteIndex = 0
        ringFilled = false
        isBuffering = true
        stateLock.unlock()

        logger.info("Started system audio buffering (\(Int(clamped), privacy: .public)s window)")
    }

    func stopBuffering() async {
        stateLock.lock()
        isBuffering = false
        ringBuffer = []
        ringCapacity = 0
        ringWriteIndex = 0
        ringFilled = false
        let stillNeeded = isWritingToFile
        stateLock.unlock()

        if !stillNeeded {
            await teardownStream()
        }
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

        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.outputSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )

        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
            )
        else {
            throw CaptureError.formatUnavailable
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress!, count: samples.count)
            }
        }

        try file.write(from: buffer)
        return Double(samples.count) / Self.outputSampleRate
    }

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

    // MARK: - Stream lifecycle

    private func ensureStreamRunning() async throws {
        stateLock.lock()
        let alreadyRunning = stream != nil
        let starting = isStartingStream
        if !alreadyRunning, !starting { isStartingStream = true }
        stateLock.unlock()
        if alreadyRunning { return }
        if starting {
            // Another caller is bringing the stream up; wait for it rather than start a second one.
            for _ in 0..<50 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                stateLock.lock(); let ready = stream != nil; let still = isStartingStream; stateLock.unlock()
                if ready { return }
                if !still { break }
            }
            throw CaptureError.formatUnavailable
        }
        defer { stateLock.lock(); isStartingStream = false; stateLock.unlock() }

        guard await Self.requestPermission() else {
            throw CaptureError.permissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw CaptureError.noDisplayAvailable
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        // Never record the user talking — this feature is explicitly system output only.
        // (Off by default; set explicitly where the API exists so intent is unambiguous.)
        if #available(macOS 15.0, *) {
            configuration.captureMicrophone = false
        }
        // Keep VoxOS's own sounds out of the transcript.
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        // Video frames are unavoidable on an SCStream, so make them as cheap as possible:
        // a 2x2 capture at 1 fps that we never register an output for.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try await newStream.startCapture()

        stateLock.lock()
        stream = newStream
        stateLock.unlock()

        logger.info("System audio stream started")
    }

    private func teardownStream() async {
        stateLock.lock()
        let current = stream
        stream = nil
        converter = nil
        converterInputFormat = nil
        stateLock.unlock()

        guard let current else { return }
        do {
            try await current.stopCapture()
        } catch {
            logger.error("Failed to stop system audio stream: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Sample handling

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

    private func converter(for inputFormat: AVAudioFormat) -> AVAudioConverter? {
        if let converter, converterInputFormat == inputFormat {
            return converter
        }
        let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat)
        converter = newConverter
        converterInputFormat = inputFormat
        return newConverter
    }
}

// MARK: - SCStreamOutput

extension SystemAudioCaptureService: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }

        stateLock.lock()
        let needsAudio = isWritingToFile || isBuffering
        stateLock.unlock()
        guard needsAudio else { return }

        guard
            let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
            let inputFormat = AVAudioFormat(streamDescription: [asbd])
        else { return }

        guard
            let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
            )
        else { return }
        inputBuffer.frameLength = inputBuffer.frameCapacity

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(inputBuffer.frameLength),
            into: inputBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return }

        stateLock.lock()
        let audioConverter = converter(for: inputFormat)
        stateLock.unlock()
        guard let audioConverter else { return }

        // 48 kHz stereo in, 16 kHz mono out — the ratio bounds the output frame count.
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1024
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

        stateLock.lock()
        if isBuffering {
            appendToRing(UnsafeBufferPointer(start: channel, count: Int(outputBuffer.frameLength)))
        }
        let file = isWritingToFile ? audioFile : nil
        stateLock.unlock()

        if let file {
            do {
                try file.write(from: outputBuffer)
            } catch {
                logger.error("Failed writing system audio: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - SCStreamDelegate

extension SystemAudioCaptureService: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logger.error("System audio stream stopped: \(error.localizedDescription, privacy: .public)")
        stateLock.lock()
        self.stream = nil
        audioFile = nil
        isWritingToFile = false
        isBuffering = false
        stateLock.unlock()
        onStreamStopped?()
    }
}
