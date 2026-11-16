@preconcurrency import AVFoundation
import AppKit
import Speech
import os

/// A teleprompter under the notch that follows the voice: the script scrolls as it is read aloud,
/// stops while the speaker pauses or ad-libs, follows a skipped sentence and goes back for a
/// repeated one. The current word is lit, what has been read dims, and notes in square brackets
/// show but are never waited for.
///
/// Speech is recognised on this Mac only (Apple's on-device recognition); where a language has no
/// on-device model the prompter says so rather than sending audio anywhere. The window stays out of
/// screenshots and screen sharing unless that is switched off, so a call never sees the script.
@MainActor
final class Prompter: ObservableObject {
    static let shared = Prompter()

    enum Problem: Equatable {
        case speechDenied
        case microphoneDenied
        case noOnDeviceModel(String)
        case failed(String)

        var message: String {
            switch self {
            case .speechDenied:
                return String(localized: "Allow Speech Recognition for VoxOS in System Settings to follow your voice.")
            case .microphoneDenied:
                return String(localized: "Allow the microphone for VoxOS in System Settings to follow your voice.")
            case .noOnDeviceModel(let language):
                return String(
                    localized: "On-device recognition isn't available for \(language), so the prompter won't listen.")
            case .failed(let reason):
                return reason
            }
        }
    }

    @Published private(set) var script = PrompterScript("")
    @Published private(set) var text = ""
    /// The spoken position of the next word to say.
    @Published private(set) var cursor = 0
    @Published private(set) var isShown = false
    @Published private(set) var isListening = false
    /// The microphone's level, 0…1, for the meter.
    @Published private(set) var level: Float = 0
    @Published private(set) var problem: Problem?

    private let audioEngine = AVAudioEngine()
    private let feed = PrompterFeed()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Bumped for each recognition task, so a late result from a finished one is ignored.
    private var generation = 0
    private let window = PrompterWindow()
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "Prompter")

    private init() {
        text = Self.loadScript()
        script = PrompterScript(text)
    }

    var hasScript: Bool { !script.spokenWords.isEmpty }
    var isFinished: Bool { hasScript && cursor >= script.spokenWords.count }

    // MARK: The script

    func setText(_ newText: String) {
        guard newText != text else { return }
        text = newText
        script = PrompterScript(newText)
        cursor = min(cursor, script.spokenWords.count)
        Self.saveScript(newText)
    }

    func loadFromClipboard() {
        guard let pasted = NSPasteboard.general.string(forType: .string),
            !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        setText(pasted)
        cursor = 0
    }

    /// Moves the place to a word clicked in the window.
    func jump(toWord index: Int) {
        cursor = script.spokenPosition(ofWord: index)
        restartRecognition()
    }

    /// Moves the place by whole words, from scrolling over the window.
    func nudge(by words: Int) {
        cursor = min(max(0, cursor + words), script.spokenWords.count)
        restartRecognition()
    }

    func restart() {
        cursor = 0
        restartRecognition()
    }

    // MARK: Showing and listening

    func toggle() {
        if isShown { stop() } else { start() }
    }

    func start() {
        guard !ProcessIdentity.isTestHost else { return }
        if isFinished { cursor = 0 }
        problem = nil
        isShown = true
        window.show()
        ActivityTrail.mark("prompter shown")
        Task { await startListening() }
    }

    func stop() {
        stopListening()
        isShown = false
        window.hide()
        ActivityTrail.mark("prompter hidden")
    }

    func toggleListening() {
        if isListening {
            stopListening()
        } else {
            Task { await startListening() }
        }
    }

    /// Settings changed (size, lines, sharing): the window follows.
    func settingsChanged() {
        window.relayout()
    }

    private func startListening() async {
        guard !isListening else { return }
        guard await Self.speechAllowed() else {
            problem = .speechDenied
            return
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            problem = .microphoneDenied
            return
        }
        let locale = Self.locale()
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition else {
            let name = Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
            problem = .noOnDeviceModel(name)
            return
        }
        self.recognizer = recognizer
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            problem = .failed(String(localized: "No microphone is available."))
            return
        }
        input.removeTap(onBus: 0)
        let feed = self.feed
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // Straight to the recogniser from the audio thread; only the meter goes to the main one.
            feed.append(buffer)
            let level = Self.meter(buffer)
            Task { @MainActor in
                guard let self else { return }
                self.level = self.level * 0.6 + level * 0.4
            }
        }
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            problem = .failed(String(localized: "The microphone could not be started."))
            logger.error("Prompter audio did not start: \(error, privacy: .public)")
            return
        }
        isListening = true
        beginRecognition()
    }

    private func stopListening() {
        guard isListening else { return }
        isListening = false
        endRecognition()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        level = 0
    }

    /// A new recognition task from the current place: after a jump, and whenever one ends (they
    /// end on long silences), so listening goes on for as long as the window shows.
    private func beginRecognition() {
        guard isListening, let recognizer else { return }
        endRecognition()
        generation += 1
        let current = generation
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.taskHint = .dictation
        request.addsPunctuation = false
        // The script's longer words help the recogniser with names and terms.
        request.contextualStrings = Array(
            Set(script.words.filter { !$0.isNote && $0.spoken.count >= 6 }.map(\.text)).prefix(100))
        self.request = request
        feed.set(request)
        let startCursor = cursor
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let heard = result?.bestTranscription.segments.map { PrompterScript.normalize($0.substring) } ?? []
            let ended = error != nil || result?.isFinal == true
            Task { @MainActor in
                guard let self, current == self.generation else { return }
                if !heard.isEmpty {
                    let next = PrompterAligner.advance(
                        from: self.cursor, script: self.script.spokenWords, heard: heard)
                    // Within one task the place only moves on, unless the match is strong (the
                    // aligner already asks more of a move back).
                    if next != self.cursor, next >= startCursor - PrompterAligner.lookBehind {
                        self.cursor = next
                    }
                }
                if ended { self.beginRecognition() }
            }
        }
    }

    private func endRecognition() {
        generation += 1
        feed.set(nil)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    private func restartRecognition() {
        guard isListening else { return }
        beginRecognition()
    }

    // MARK: Helpers

    private static func speechAllowed() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        }
    }

    /// Dictation's language, or the system's when dictation detects it.
    private static func locale() -> Locale {
        let selected = UserDefaults.standard.string(forKey: DefaultsKeys.selectedLanguage) ?? "en"
        return selected == "auto" || selected.isEmpty ? Locale.current : Locale(identifier: selected)
    }

    nonisolated private static func meter(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) { sum += channel[index] * channel[index] }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        // About -50 dB to -10 dB across the meter.
        return min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 40))
    }

    private static var scriptURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.achyuthkp.VoxOS/prompter.txt")
    }

    private static func loadScript() -> String {
        (try? String(contentsOf: scriptURL, encoding: .utf8)) ?? sampleScript
    }

    private static func saveScript(_ text: String) {
        let url = scriptURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    static let sampleScript = String(
        localized: """
            Welcome! This is the VoxOS prompter. Read this aloud and the text follows your voice. [pause]

            Stop talking and it waits for you. Skip a sentence and it catches up; go back and it goes back with you.

            Words in square brackets are notes for you. They show, but the prompter never waits for them. [smile]

            Paste your own script in Settings, or copy it and choose Load from Clipboard.
            """)
}

/// The recognition request the microphone feeds, swapped from the main thread and fed from the
/// audio thread.
final class PrompterFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) { lock.withLock { self.request = request } }

    func append(_ buffer: AVAudioPCMBuffer) { lock.withLock { request }?.append(buffer) }
}
