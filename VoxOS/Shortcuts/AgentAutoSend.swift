import Foundation

/// Hands-free Agent recordings end themselves: once the user has spoken and then stayed quiet
/// for a moment, the recording stops and the request goes to the agent — no second tap needed.
/// Dictation modes are untouched (people pause while dictating); only the Agent mode auto-sends.
@MainActor
final class AgentAutoSend {
    private weak var engine: VoxOSEngine?
    private weak var recorderUIManager: RecorderUIManager?
    private var task: Task<Void, Never>?

    /// Normalised meter level (0…1) treated as speech.
    static let speechThreshold = 0.10
    /// Quiet time after speech before the recording is sent.
    static let silenceToSend: TimeInterval = 1.4
    /// Give up waiting for speech after this long.
    static let maxWaitForSpeech: TimeInterval = 12
    static let maxRecording: TimeInterval = 90

    init(engine: VoxOSEngine, recorderUIManager: RecorderUIManager) {
        self.engine = engine
        self.recorderUIManager = recorderUIManager
    }

    func startIfAgentMode() {
        cancel()
        guard ModeManager.shared.currentEffectiveConfiguration?.id == StarterModeCatalog.agentId,
            let engine, engine.recordingState == .recording
        else { return }

        task = Task { @MainActor [weak self] in
            let started = Date()
            var heardSpeech = false
            var lastSpeechAt = Date()
            var lastTranscript = ""
            var transcriptChangedAt = Date()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, let engine = self.engine, engine.recordingState == .recording,
                    ModeManager.shared.currentEffectiveConfiguration?.id == StarterModeCatalog.agentId
                else { return }

                let now = Date()
                let level = engine.recorder.audioMeterSnapshot().averagePower
                if level >= Self.speechThreshold {
                    heardSpeech = true
                    lastSpeechAt = now
                }
                if engine.partialTranscript != lastTranscript {
                    lastTranscript = engine.partialTranscript
                    transcriptChangedAt = now
                    if !lastTranscript.isEmpty { heardSpeech = true }
                }

                let quietFor = now.timeIntervalSince(max(lastSpeechAt, transcriptChangedAt))
                if !heardSpeech, now.timeIntervalSince(started) >= Self.maxWaitForSpeech {
                    // Opened the Agent and said nothing: close quietly instead of sending silence.
                    self.task = nil
                    await self.recorderUIManager?.cancelRecording()
                    return
                }

                let shouldSend =
                    (heardSpeech && quietFor >= Self.silenceToSend)
                    || now.timeIntervalSince(started) >= Self.maxRecording

                if shouldSend {
                    self.task = nil
                    await self.recorderUIManager?.toggleRecorderPanel()
                    return
                }
            }
        }
    }

    /// Waits briefly for the recorder to reach `.recording` (permission preflight, audio start)
    /// and then arms the silence watcher.
    func startWhenRecording() {
        cancel()
        task = Task { @MainActor [weak self] in
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                guard let self, let engine = self.engine, !Task.isCancelled else { return }
                if engine.recordingState == .recording {
                    self.task = nil
                    self.startIfAgentMode()
                    return
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}
