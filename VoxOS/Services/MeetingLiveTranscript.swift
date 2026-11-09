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

/// What is being said in a meeting, as it is said.
///
/// With a speech model that streams (Parakeet Unified and Ultra do, on this Mac), the call and
/// the microphone are mixed and fed to it every quarter second and the text grows word by word.
/// The stream starts afresh every few minutes, so an hour's meeting never holds an hour of
/// audio in the model; what came before stays as finished paragraphs. A model that cannot
/// stream is sent the last few seconds at a time instead.
///
/// A preview only. The notes saved to History are written from the whole recording afterwards,
/// with who spoke.
@MainActor
final class MeetingLiveTranscript: ObservableObject {
    static let shared = MeetingLiveTranscript()

    struct Line: Identifiable, Equatable {
        let id = UUID()
        let time: Date
        let text: String
    }

    /// Finished paragraphs, oldest first.
    @Published private(set) var lines: [Line] = []
    /// The paragraph being said now, growing as the model hears it.
    @Published private(set) var current = ""
    @Published private(set) var currentStarted: Date?
    @Published private(set) var title = ""
    @Published private(set) var startedAt: Date?
    @Published private(set) var isRunning = false
    @Published private(set) var isStreaming = false
    @Published private(set) var problem: String?

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: DefaultsKeys.meetingNotesLiveTranscript) as? Bool ?? true
    }

    /// How often new audio is fed to a streaming model.
    nonisolated static let feedInterval: Double = 0.25
    /// A streaming session's length before it starts afresh, bounding what the model holds.
    nonisolated static let rolloverSeconds: Double = 300
    /// For a model that cannot stream: short enough to follow the conversation.
    nonisolated static let chunkSeconds: Double = 5
    /// Below this a chunk is silence or room noise, which batch speech models fill with
    /// made-up words ("Thank you."), so it is skipped.
    nonisolated static let silenceFloor: Float = -50

    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "MeetingLiveTranscript")
    private var task: Task<Void, Never>?
    private var registry: TranscriptionServiceRegistry?
    private var stream: StreamingTranscriptionService?
    private var streamStarted = Date()
    private var configuration: TranscriptionRuntimeConfiguration?
    private weak var microphone: MeetingMicrophone?

    private init() {}

    var allText: String { (lines.map(\.text) + (current.isEmpty ? [] : [current])).joined(separator: "\n\n") }

    func start(title: String, engine: VoxOSEngine, mode: ModeConfig, microphone: MeetingMicrophone?) {
        task?.cancel()
        lines = []
        current = ""
        currentStarted = nil
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
        self.configuration = configuration
        let registry = TranscriptionServiceRegistry(
            modelProvider: engine.whisperModelManager,
            modelsDirectory: engine.whisperModelManager.modelsDirectory,
            modelContext: engine.modelContext)
        self.registry = registry
        isStreaming = configuration.model.supportsStreaming
        if isStreaming {
            task = Task { [weak self] in await self?.runStreaming(engine: engine) }
        } else {
            task = Task { [weak self] in await self?.runChunks() }
        }
    }

    func stop() async {
        task?.cancel()
        task = nil
        finishParagraph()
        stream?.cancel()
        stream = nil
        isRunning = false
        SystemAudioCaptureService.shared.stopLive()
        await registry?.cleanup()
        registry = nil
        configuration = nil
        microphone = nil
    }

    // MARK: Streaming

    private func runStreaming(engine: VoxOSEngine) async {
        await startStream(engine: engine)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.feedInterval))
            guard !Task.isCancelled else { return }
            let mixed = takeMixed()
            if !mixed.isEmpty { stream?.sendAudioChunk(Self.pcm16(mixed)) }
            if Date().timeIntervalSince(streamStarted) >= Self.rolloverSeconds {
                finishParagraph()
                let old = stream
                await startStream(engine: engine)
                old?.cancel()
            }
        }
    }

    private func startStream(engine: VoxOSEngine) async {
        guard let configuration, let registry else { return }
        let model = configuration.model
        let stream = StreamingTranscriptionService(
            modelContext: engine.modelContext,
            fluidAudioService: model.provider == .fluidAudio ? registry.fluidAudioTranscriptionService : nil,
            onPartialTranscript: { [weak self] text in
                Task { @MainActor in self?.heard(text) }
            })
        self.stream = stream
        streamStarted = Date()
        do {
            try await stream.startStreaming(model: model, context: configuration.requestContext.scoped(to: model))
            problem = nil
        } catch {
            logger.error("Live transcript stream did not start: \(error, privacy: .public)")
            problem = String(localized: "The live transcript could not start; the notes in History will still have it.")
        }
    }

    /// The stream's running text for this session, which replaces what it said before.
    private func heard(_ text: String) {
        guard isRunning else { return }
        let text = TranscriptionOutputFilter.filter(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if currentStarted == nil, !text.isEmpty { currentStarted = Date() }
        current = text
    }

    /// Moves what is being said into the finished paragraphs.
    private func finishParagraph() {
        if !current.isEmpty { lines.append(Line(time: currentStarted ?? Date(), text: current)) }
        current = ""
        currentStarted = nil
    }

    // MARK: Chunks, for a model that cannot stream

    private func runChunks() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.chunkSeconds))
            guard !Task.isCancelled else { return }
            await transcribeChunk()
        }
    }

    private func transcribeChunk() async {
        let mixed = takeMixed()
        guard Self.isWorthTranscribing(mixed), let registry, let configuration else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "voxos-live-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try SystemAudioCaptureService.write(mixed, to: url)
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

    // MARK: Audio

    private func takeMixed() -> [Float] {
        MeetingAudioMixer.mixed(
            SystemAudioCaptureService.shared.takeLiveSamples(), microphone?.takeLiveSamples() ?? [])
    }

    /// 16-bit little-endian PCM, the form the streaming models take.
    nonisolated static func pcm16(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = Int16(max(-1, min(1, sample)) * Float(Int16.max))
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
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
final class LiveTranscriptWindow: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = LiveTranscriptWindow()
    private var panel: NSPanel?
    /// Whether the window is on screen. Hiding it never stops the meeting's recording.
    @Published private(set) var isShown = false

    private override init() {}

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        // A screen share must not show the call's words when the notch is set to stay out of them.
        panel.sharingType =
            UserDefaults.standard.bool(forKey: DefaultsKeys.notchHiddenFromCapture) ? .none : .readOnly
        panel.orderFrontRegardless()
        isShown = true
    }

    func close() {
        panel?.orderOut(nil)
        isShown = false
    }

    /// From the menu bar and the shortcut. With no meeting recording and nothing to read, there
    /// is no transcript to show, so it says so instead of opening an empty window.
    func toggle() {
        if isShown {
            close()
        } else if MeetingNotes.shared.session != nil || !MeetingLiveTranscript.shared.allText.isEmpty {
            show()
        } else {
            NotificationManager.shared.showNotification(
                title: String(localized: "No meeting is being recorded, so there is no live transcript."), type: .info)
        }
    }

    func windowWillClose(_ notification: Notification) {
        isShown = false
    }

    private func makePanel() -> NSPanel {
        let size = NSSize(width: 380, height: 480)
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: visible.maxX - size.width - 20, y: visible.maxY - size.height - 20)
        let panel = LiveTranscriptPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.title = String(localized: "Live Transcript")
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        // The card draws its own rounded surface and shadow.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.minSize = NSSize(width: 320, height: 300)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        let host = NSHostingView(rootView: MeetingTranscriptView())
        host.wantsLayer = true
        host.layer?.backgroundColor = .clear
        panel.contentView = host
        return panel
    }
}

/// Borderless, but able to take clicks and text selection without bringing VoxOS forward.
private final class LiveTranscriptPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The live transcript as a floating card: a header with the meeting and its clock, the words
/// as tonal cards with the one being said highlighted, and a footer with Stop.
struct MeetingTranscriptView: View {
    private static let currentID = "current"
    @ObservedObject private var live = MeetingLiveTranscript.shared
    @ObservedObject private var notes = MeetingNotes.shared
    @State private var copied = false

    private let corner: CGFloat = 20

    var body: some View {
        VStack(spacing: 0) {
            header
            transcript
            footer
        }
        .background(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(.regularMaterial)
        )
        .background(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(AppTheme.Accent.wash.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(AppTheme.Border.card, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
        .padding(14)
        .frame(minWidth: 320, minHeight: 300)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            LiveChip(isLive: live.isRunning)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: live.title)
                    .font(.app(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Text(verbatim: live.title))
                // The clock rides on the subtitle, so the title keeps the row's width.
                HStack(spacing: 4) {
                    Text(live.isStreaming ? "Live transcript" : "Live transcript, every few seconds")
                    if let start = live.startedAt, live.isRunning {
                        Text(verbatim: "·")
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(verbatim: Self.elapsed(from: start, to: context.date))
                                .monospacedDigit()
                        }
                    }
                }
                .font(.app(size: 11))
                .foregroundStyle(AppTheme.Text.secondary)
                .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy") { copy() }
                .disabled(live.allText.isEmpty)
            IconButton(symbol: "minus", help: "Hide the live transcript; the meeting keeps recording") {
                LiveTranscriptWindow.shared.close()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if live.lines.isEmpty, live.current.isEmpty {
                        emptyState
                    }
                    ForEach(live.lines) { line in
                        ParagraphCard(time: line.time, text: line.text, isCurrent: false, isListening: false)
                            .id(line.id)
                    }
                    if !live.current.isEmpty {
                        ParagraphCard(
                            time: live.currentStarted, text: live.current, isCurrent: true,
                            isListening: live.isRunning
                        )
                        .id(Self.currentID)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.never)
            .onChange(of: live.current) { _, _ in
                proxy.scrollTo(Self.currentID, anchor: .bottom)
            }
            .onChange(of: live.lines.count) { _, _ in
                guard live.current.isEmpty, let last = live.lines.last else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(AppTheme.Accent.fill).frame(width: 52, height: 52)
                Image(systemName: "waveform")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(AppTheme.Accent.primary)
                    .symbolEffect(.variableColor.iterative, isActive: live.isRunning)
            }
            Text(live.isRunning ? "Listening" : "Nothing was said")
                .font(.app(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primary)
            Text(
                live.isStreaming
                    ? "Words show here as they are said."
                    : "Words show here every few seconds; this speech model cannot stream."
            )
            .font(.app(size: 12))
            .foregroundStyle(AppTheme.Text.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(live.problem == nil ? AppTheme.Text.secondary : AppTheme.Status.warning)
            Text(status)
                .font(.app(size: 11))
                .foregroundStyle(AppTheme.Text.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if notes.session != nil {
                Button {
                    Task { await notes.stop() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.app(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(AppTheme.Status.error))
                        .shadow(color: AppTheme.Status.error.opacity(0.35), radius: 6, y: 2)
                }
                .buttonStyle(.plain)
                .help("Stop Meeting Notes")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppTheme.Surface.subtle)
    }

    private var status: String {
        if let problem = live.problem { return problem }
        if !live.isRunning { return String(localized: "Meeting ended. The notes are being written up in History.") }
        return String(localized: "Listening…")
    }

    private var statusSymbol: String {
        if live.problem != nil { return "exclamationmark.triangle.fill" }
        return live.isRunning ? "mic.fill" : "checkmark.circle.fill"
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(live.allText, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// "LIVE" with a pulsing dot while recording; "ENDED" once the meeting stops.
private struct LiveChip: View {
    let isLive: Bool
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isLive ? AppTheme.Status.error : AppTheme.Text.muted)
                .frame(width: 7, height: 7)
                .scaleEffect(isLive && pulse ? 1.35 : 1)
                .opacity(isLive && pulse ? 0.55 : 1)
            Text(isLive ? "LIVE" : "ENDED")
                .font(.appMono(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(isLive ? AppTheme.Status.error : AppTheme.Text.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill((isLive ? AppTheme.Status.error : AppTheme.Text.muted).opacity(0.14)))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// A round tonal icon button for the header.
private struct IconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(hovered ? AppTheme.Surface.controlActive : AppTheme.Surface.control))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

/// One paragraph of the transcript. The one being said has an accent edge and a typing dot.
private struct ParagraphCard: View {
    let time: Date?
    let text: String
    let isCurrent: Bool
    let isListening: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(isCurrent ? AppTheme.Accent.primary : Color.clear)
                .frame(width: 3)
                .padding(.vertical, 10)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if let time {
                        Text(time, style: .time)
                            .font(.appMono(size: 10, weight: .semibold))
                            .foregroundStyle(isCurrent ? AppTheme.Accent.primary : AppTheme.Text.muted)
                    }
                    if isCurrent, isListening {
                        TypingDots()
                    }
                }
                Text(verbatim: text)
                    .font(.app(size: 13.5))
                    .foregroundStyle(AppTheme.Text.primary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Spacer(minLength: 0)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isCurrent ? AppTheme.Accent.fillSubtle : AppTheme.Surface.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isCurrent ? AppTheme.Accent.border.opacity(0.5) : AppTheme.Border.subtle, lineWidth: 1)
        )
    }
}

/// Three dots that rise in turn while the model is still hearing this paragraph.
private struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * 3
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(AppTheme.Accent.primary)
                        .frame(width: 4, height: 4)
                        .opacity(0.35 + 0.65 * max(0, sin(phase - Double(index) * 0.7)))
                }
            }
        }
    }
}
