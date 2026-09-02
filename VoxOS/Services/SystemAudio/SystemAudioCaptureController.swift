import AVFoundation
import Foundation
import SwiftData
import SwiftUI
import os

/// Drives the two system-audio flows and delivers the result: transcribe what the Mac
/// played, copy it to the clipboard, and paste it at the cursor.
///
/// - **Capture**: a shortcut starts recording system output and a second press stops it.
/// - **Recall**: a rolling in-memory buffer is transcribed on demand ("what did they just say?").
@MainActor
final class SystemAudioCaptureController: ObservableObject {
    static let shared = SystemAudioCaptureController()

    /// Defaults keys, kept alongside the `@AppStorage` bindings in Settings.
    enum DefaultsKey {
        static let bufferEnabled = "systemAudioBufferEnabled"
        static let bufferSeconds = "systemAudioBufferSeconds"
        static let pasteAtCursor = "systemAudioPasteAtCursor"
        static let saveToHistory = "systemAudioSaveToHistory"
    }

    static let defaultBufferSeconds: Double = 30

    @Published private(set) var isCapturing = false
    @Published private(set) var isTranscribing = false
    @Published private(set) var isBufferRunning = false

    private let capture = SystemAudioCaptureService.shared
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "SystemAudioController")
    private weak var engine: VoxOSEngine?
    private var currentCaptureURL: URL?

    private init() {}

    func configure(engine: VoxOSEngine) {
        self.engine = engine
        Task { await self.syncBufferingWithPreference() }
    }

    // MARK: - Preferences

    var isBufferEnabled: Bool {
        UserDefaults.standard.object(forKey: DefaultsKey.bufferEnabled) as? Bool ?? false
    }

    var bufferSeconds: Double {
        let stored = UserDefaults.standard.double(forKey: DefaultsKey.bufferSeconds)
        return stored > 0 ? stored : Self.defaultBufferSeconds
    }

    private var shouldPasteAtCursor: Bool {
        UserDefaults.standard.object(forKey: DefaultsKey.pasteAtCursor) as? Bool ?? true
    }

    private var shouldSaveToHistory: Bool {
        UserDefaults.standard.object(forKey: DefaultsKey.saveToHistory) as? Bool ?? true
    }

    /// Starts or stops the rolling buffer to match the user's preference.
    func syncBufferingWithPreference() async {
        if isBufferEnabled {
            guard !capture.isBufferingRecentAudio else { return }
            do {
                try await capture.startBuffering(seconds: bufferSeconds)
                isBufferRunning = true
            } catch {
                isBufferRunning = false
                report(error)
            }
        } else if capture.isBufferingRecentAudio {
            await capture.stopBuffering()
            isBufferRunning = false
        }
    }

    // MARK: - Capture (press to start, press to stop)

    func toggleCapture() async {
        if isCapturing {
            await finishCapture()
        } else {
            await beginCapture()
        }
    }

    private func beginCapture() async {
        guard !isTranscribing else { return }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxos-system-audio-\(UUID().uuidString).wav")

        do {
            try await capture.startCapture(to: url)
            currentCaptureURL = url
            isCapturing = true
        } catch {
            report(error)
        }
    }

    private func finishCapture() async {
        let duration = await capture.stopCapture()
        isCapturing = false

        guard let url = currentCaptureURL else { return }
        currentCaptureURL = nil

        guard duration >= 0.3 else {
            try? FileManager.default.removeItem(at: url)
            logger.info("System audio capture too short to transcribe")
            return
        }

        await transcribeAndDeliver(url: url, duration: duration, deleteAudioWhenDone: !shouldSaveToHistory)
    }

    // MARK: - Recall (transcribe the last N seconds)

    func transcribeRecentAudio() async {
        guard !isTranscribing else { return }

        guard capture.isBufferingRecentAudio else {
            logger.info("Recall requested but system audio buffering is off")
            return
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxos-system-audio-recall-\(UUID().uuidString).wav")

        do {
            let seconds = try capture.writeRecentAudio(seconds: bufferSeconds, to: url)
            await transcribeAndDeliver(url: url, duration: seconds, deleteAudioWhenDone: !shouldSaveToHistory)
        } catch {
            report(error)
        }
    }

    // MARK: - Agent access (returns text; never pastes)

    func agentStart() async -> [String: Any] {
        if isCapturing { return ["ok": true, "note": "already capturing system audio"] }
        await beginCapture()
        return isCapturing ? ["ok": true, "note": "capturing what the Mac plays; call system_audio_stop to get the transcript"]
            : ["error": "could not start system audio capture — Screen Recording permission may be missing"]
    }

    func agentStop() async -> [String: Any] {
        guard isCapturing else { return ["error": "not capturing; call system_audio_start first"] }
        let duration = await capture.stopCapture()
        isCapturing = false
        guard let url = currentCaptureURL else { return ["error": "no capture file"] }
        currentCaptureURL = nil
        guard duration >= 0.3 else {
            try? FileManager.default.removeItem(at: url)
            return ["error": "nothing was playing"]
        }
        let text = await transcribeText(url: url) ?? ""
        try? FileManager.default.removeItem(at: url)
        return text.isEmpty ? ["error": "no speech found in the captured audio"] : ["ok": true, "seconds": Int(duration), "transcript": text]
    }

    func agentRecall(seconds: Double) async -> [String: Any] {
        guard capture.isBufferingRecentAudio else {
            return ["error": "system audio buffering is off; the user can enable “Keep Recent System Audio” in Settings → System Audio"]
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voxos-agent-recall-\(UUID().uuidString).wav")
        do {
            let written = try capture.writeRecentAudio(seconds: min(seconds, bufferSeconds), to: url)
            let text = await transcribeText(url: url) ?? ""
            try? FileManager.default.removeItem(at: url)
            return text.isEmpty ? ["error": "no speech in the last \(Int(written))s"] : ["ok": true, "seconds": Int(written), "transcript": text]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    /// Transcribes a file with the active mode's model. Shared by the shortcut flow, the
    /// agent tools and the audio watcher.
    func transcribeText(url: URL) async -> String? {
        guard let engine,
            let configuration = ModeRuntimeResolver.transcriptionConfiguration(transcriptionModelManager: engine.transcriptionModelManager)
        else { return nil }
        let text = try? await engine.serviceRegistry.transcribe(audioURL: url, model: configuration.model, context: configuration.requestContext)
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Transcription + delivery

    private func transcribeAndDeliver(url: URL, duration: TimeInterval, deleteAudioWhenDone: Bool) async {
        guard let engine else {
            logger.error("No engine configured; system audio transcription skipped")
            return
        }
        // Resolve the model the same way the dictation pipeline does, so system audio
        // honours the active mode's model, language and prompt rather than a bare default.
        guard
            let configuration = ModeRuntimeResolver.transcriptionConfiguration(
                transcriptionModelManager: engine.transcriptionModelManager
            )
        else {
            logger.error("No transcription model available for system audio")
            try? FileManager.default.removeItem(at: url)
            return
        }
        let model = configuration.model

        isTranscribing = true
        defer { isTranscribing = false }

        do {
            logger.info(
                "Transcribing \(String(format: "%.1f", duration), privacy: .public)s of system audio with \(model.displayName, privacy: .public)"
            )
            let text = try await engine.serviceRegistry.transcribe(
                audioURL: url,
                model: model,
                context: configuration.requestContext
            )
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            logger.info("System audio transcript: \(trimmed.count, privacy: .public) characters")

            guard !trimmed.isEmpty else {
                logger.info("No speech found in captured system audio")
                try? FileManager.default.removeItem(at: url)
                return
            }

            deliver(trimmed)

            if shouldSaveToHistory {
                save(text: trimmed, duration: duration, audioURL: url, modelName: model.displayName)
            } else if deleteAudioWhenDone {
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            report(error)
        }
    }

    private func deliver(_ text: String) {
        _ = ClipboardManager.copyToClipboard(text)

        if shouldPasteAtCursor {
            // Matches the delay LastTranscriptionService uses so the frontmost app has
            // settled before the paste keystroke is posted.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                CursorPaster.pasteAtCursor(text)
            }
        }

    }

    private func save(text: String, duration: TimeInterval, audioURL: URL, modelName: String) {
        guard let engine else { return }

        let transcription = Transcription(
            text: text,
            duration: duration,
            audioFileURL: audioURL.absoluteString,
            transcriptionModelName: modelName,
            modeName: String(localized: "System Audio"),
            modeEmoji: "🔊",
            transcriptionStatus: .completed
        )
        engine.modelContext.insert(transcription)
        try? engine.modelContext.save()
        NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
    }

    /// This flow is deliberately silent — no toasts on success or failure. The text
    /// arriving in the clipboard and the focused field is the only feedback; everything
    /// else goes to the log so failures stay diagnosable without interrupting the user.
    private func report(_ error: Error) {
        logger.error("System audio failure: \(error.localizedDescription, privacy: .public)")
    }
}
