import AVFoundation
import AppKit
import SwiftUI
import os

/// A meeting's microphone: written to a 16 kHz mono WAV like the call's own recording, so the
/// two mix sample for sample, and handed out as it arrives for the live transcript.
final class MeetingMicrophone: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "MeetingMicrophone")
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: SystemAudioCaptureService.outputSampleRate, channels: 1,
        interleaved: false)!
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var live: [Float] = []
    private var collectsLive = false

    func start(to url: URL, live: Bool) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { throw SystemAudioCaptureService.CaptureError.formatUnavailable }
        // A stereo or multichannel input is mixed down rather than reduced to its first channel.
        converter.downmix = true
        let file = try AVAudioFile(forWriting: url, settings: SystemAudioCaptureService.fileSettings)
        lock.withLock {
            self.converter = converter
            self.file = file
            self.live = []
            self.collectsLive = live
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.consume(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        lock.withLock {
            file = nil
            converter = nil
            live = []
        }
    }

    /// The 16 kHz mono samples that arrived since the last call.
    func takeLiveSamples() -> [Float] {
        lock.withLock {
            let taken = live
            live = []
            return taken
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard let converter = lock.withLock({ self.converter }) else { return }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, converted.frameLength > 0, let channel = converted.floatChannelData?[0] else { return }
        lock.withLock {
            do {
                try file?.write(from: converted)
            } catch {
                logger.error("Failed writing the meeting's microphone: \(error.localizedDescription, privacy: .public)")
            }
            guard collectsLive else { return }
            live.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
            let limit = Int(SystemAudioCaptureService.maximumLiveSeconds * SystemAudioCaptureService.outputSampleRate)
            if live.count > limit { live.removeFirst(live.count - limit) }
        }
    }
}

/// What is being said in a meeting, a few seconds behind: every `chunkSeconds` the call and the
/// microphone that arrived meanwhile are mixed and transcribed with the mode's speech model.
///
/// A preview only. The notes saved to History are written from the whole recording afterwards,
/// with who spoke, so a word cut at a chunk's edge here is whole there.
@MainActor
final class MeetingLiveTranscript: ObservableObject {
    static let shared = MeetingLiveTranscript()

    struct Line: Identifiable, Equatable {
        let id = UUID()
        let time: Date
        let text: String
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var title = ""
    @Published private(set) var startedAt: Date?
    @Published private(set) var isRunning = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var problem: String?

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: DefaultsKeys.meetingNotesLiveTranscript) as? Bool ?? true
    }

    /// Long enough for whole sentences, short enough to feel live.
    nonisolated static let chunkSeconds: Double = 15
    /// Below this the chunk is silence or room noise, which speech models fill with made-up
    /// words ("Thank you."), so it is skipped.
    nonisolated static let silenceFloor: Float = -50

    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "MeetingLiveTranscript")
    private var task: Task<Void, Never>?
    private var registry: TranscriptionServiceRegistry?
    private weak var microphone: MeetingMicrophone?

    private init() {}

    func start(title: String, engine: VoxOSEngine, mode: ModeConfig, microphone: MeetingMicrophone?) {
        stopLoop()
        lines = []
        problem = nil
        self.title = title
        startedAt = Date()
        isRunning = true
        self.microphone = microphone
        guard
            let configuration = ModeRuntimeResolver.transcriptionConfiguration(
                mode: mode, transcriptionModelManager: engine.transcriptionModelManager)
        else {
            problem = String(localized: "No speech model is set up, so the live transcript is off.")
            return
        }
        do {
            try SystemAudioCaptureService.shared.startLive()
        } catch {
            problem = error.localizedDescription
            return
        }
        registry = TranscriptionServiceRegistry(
            modelProvider: engine.whisperModelManager,
            modelsDirectory: engine.whisperModelManager.modelsDirectory,
            modelContext: engine.modelContext)
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.chunkSeconds))
                guard let self, !Task.isCancelled else { return }
                await self.transcribeChunk(configuration)
            }
        }
    }

    func stop() async {
        stopLoop()
        isRunning = false
        isTranscribing = false
        SystemAudioCaptureService.shared.stopLive()
        await registry?.cleanup()
        registry = nil
        microphone = nil
    }

    private func stopLoop() {
        task?.cancel()
        task = nil
    }

    private func transcribeChunk(_ configuration: TranscriptionRuntimeConfiguration) async {
        let mixed = MeetingAudioMixer.mixed(
            SystemAudioCaptureService.shared.takeLiveSamples(), microphone?.takeLiveSamples() ?? [])
        guard Self.isWorthTranscribing(mixed), let registry else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "voxos-live-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try SystemAudioCaptureService.write(mixed, to: url)
            isTranscribing = true
            defer { isTranscribing = false }
            let text = TranscriptionOutputFilter.filter(
                try await registry.transcribe(
                    audioURL: url, model: configuration.model, context: configuration.requestContext)
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard isRunning, !text.isEmpty else { return }
            lines.append(Line(time: Date(), text: text))
            problem = nil
        } catch {
            logger.error("Live transcript chunk failed: \(error, privacy: .public)")
            problem = String(localized: "A part could not be transcribed; the notes in History will still have it.")
        }
    }

    /// At least a second of audio, loud enough to hold speech.
    nonisolated static func isWorthTranscribing(_ samples: [Float]) -> Bool {
        guard samples.count >= Int(SystemAudioCaptureService.outputSampleRate) else { return false }
        return samples.withUnsafeBufferPointer { CoreAudioRecorder.meterLevels($0).average } > silenceFloor
    }
}

// MARK: - Window

/// The live transcript's floating window, beside the call rather than over it.
@MainActor
final class LiveTranscriptWindow {
    static let shared = LiveTranscriptWindow()
    private var panel: NSPanel?

    private init() {}

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        // A screen share must not show the call's words when the notch is set to stay out of them.
        panel.sharingType =
            UserDefaults.standard.bool(forKey: DefaultsKeys.notchHiddenFromCapture) ? .none : .readOnly
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 360, height: 440)
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: visible.maxX - size.width - 20, y: visible.maxY - size.height - 20)
        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = String(localized: "Live Transcript")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: MeetingTranscriptView())
        return panel
    }
}

struct MeetingTranscriptView: View {
    @ObservedObject private var live = MeetingLiveTranscript.shared
    @ObservedObject private var notes = MeetingNotes.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            footer
        }
        .frame(minWidth: 300, minHeight: 240)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(live.isRunning ? Color.red : Color.secondary)
                .frame(width: 8, height: 8)
            Text(verbatim: live.title)
                .font(.app(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer()
            if live.isRunning, let start = live.startedAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(verbatim: Self.elapsed(from: start, to: context.date))
                        .font(.appMono(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(12)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if live.lines.isEmpty {
                        Text("What is said shows here a few seconds later.")
                            .font(.app(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(live.lines) { line in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(line.time, style: .time)
                                .font(.appMono(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(verbatim: line.text)
                                .font(.app(size: 13))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .id(line.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .onChange(of: live.lines.count) { _, _ in
                guard let last = live.lines.last else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(status)
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("Copy") {
                let text = live.lines.map(\.text).joined(separator: "\n\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .disabled(live.lines.isEmpty)
            if notes.session != nil {
                Button("Stop") { Task { await notes.stop() } }
                    .help("Stop Meeting Notes")
            }
        }
        .controlSize(.small)
        .padding(10)
    }

    private var status: String {
        if let problem = live.problem { return problem }
        if !live.isRunning { return String(localized: "Meeting ended. The notes are being written up in History.") }
        return live.isTranscribing ? String(localized: "Transcribing…") : String(localized: "Listening…")
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
