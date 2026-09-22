import Foundation
import os

/// Decides when a hands-free Agent recording is finished. Pure and clock-injected so it can be
/// tested with level traces.
///
/// Levels come from the recorder meter, which maps -60…0 dB onto 0…1. A quiet room already sits
/// around 0.15–0.35 on that scale, so a fixed "speech" threshold never sees silence. Instead the
/// detector learns the room's noise floor, calls anything clearly above it speech, and sends once
/// the level has been back near the floor for the pause length. When a room is too noisy for that
/// (TV, café), a live transcript that has stopped changing ends the recording instead.
struct AutoSendDetector {
    enum Decision: Equatable {
        case keepListening
        case send
        case giveUp
    }

    static let calibration: TimeInterval = 0.35
    /// The meter reads ~0 until the microphone is running; those samples say nothing about the room.
    static let warmUpLevel = 0.03
    /// Used if the meter never produced a real reading during calibration.
    static let fallbackFloor = 0.3
    /// Once speech has been heard, the transcript only needs to be this still (it lags the audio).
    static let transcriptQuiet: TimeInterval = 0.6
    /// ≈7 dB above the floor counts as speech.
    static let speechMargin = 0.12
    /// Speech must add up to this much before a pause can end the recording.
    static let minimumSpeech: TimeInterval = 0.3
    /// Extra settle time before a frozen transcript alone ends the recording.
    static let transcriptOnlyExtra: TimeInterval = 1.2
    static let maxWaitForSpeech: TimeInterval = 12
    static let maxRecording: TimeInterval = 90

    let pause: TimeInterval
    let startedAt: Date

    private(set) var noiseFloor: Double?
    private(set) var heardSpeech = false
    private var calibrationLevels: [Double] = []
    private var speechTime: TimeInterval = 0
    private var lastSampleAt: Date
    private(set) var lastLoudAt: Date
    private var lastTranscript = ""
    private(set) var transcriptChangedAt: Date

    init(pause: TimeInterval, startedAt: Date) {
        self.pause = pause
        self.startedAt = startedAt
        lastSampleAt = startedAt
        lastLoudAt = startedAt
        transcriptChangedAt = startedAt
    }

    mutating func feed(level: Double, transcript: String, at now: Date) -> Decision {
        let elapsed = now.timeIntervalSince(startedAt)
        let step = max(0, min(0.5, now.timeIntervalSince(lastSampleAt)))
        lastSampleAt = now

        if transcript != lastTranscript {
            lastTranscript = transcript
            transcriptChangedAt = now
            if !transcript.trimmingCharacters(in: .whitespaces).isEmpty { heardSpeech = true }
        }

        if elapsed >= Self.maxRecording { return .send }

        if noiseFloor == nil {
            if level > Self.warmUpLevel { calibrationLevels.append(level) }
            let enoughSamples = calibrationLevels.count >= 3
            guard (elapsed >= Self.calibration && enoughSamples) || elapsed >= 1.0 else { return .keepListening }
            // The quietest real sample: someone who starts talking at once still leaves gaps
            // between words, and the floor falls to them quickly below.
            noiseFloor = calibrationLevels.min() ?? Self.fallbackFloor
        }
        guard level > Self.warmUpLevel else { return .keepListening }
        var floor = noiseFloor ?? Self.fallbackFloor

        let loud = level >= floor + Self.speechMargin
        if loud {
            lastLoudAt = now
            speechTime += step
            if speechTime >= Self.minimumSpeech { heardSpeech = true }
        }
        if level < floor {
            floor = floor * 0.6 + level * 0.4
        } else {
            // Always creep towards the current level, loud or not: a floor that started too low
            // corrects itself within a few seconds, while a short burst of speech barely moves it.
            floor += (level - floor) * 0.012
        }
        noiseFloor = floor

        if !heardSpeech {
            return elapsed >= Self.maxWaitForSpeech ? .giveUp : .keepListening
        }

        let quiet = now.timeIntervalSince(lastLoudAt)
        let transcriptSettled = now.timeIntervalSince(transcriptChangedAt)
        if quiet >= pause && transcriptSettled >= min(pause, Self.transcriptQuiet) {
            return .send
        }
        if !lastTranscript.isEmpty, transcriptSettled >= pause + Self.transcriptOnlyExtra {
            return .send
        }
        return .keepListening
    }
}

/// Hands-free Agent recordings end themselves: once the user has spoken and then paused, the
/// recording stops and the request goes to the Agent — no second tap. Dictation modes are
/// untouched (people pause while dictating); only the Agent mode auto-sends.
@MainActor
final class AgentAutoSend {
    enum Pause: Double, CaseIterable, Identifiable {
        case quick = 1.0
        case normal = 1.5
        case relaxed = 2.2

        var id: Double { rawValue }

        var label: String {
            switch self {
            case .quick: return String(localized: "Quick")
            case .normal: return String(localized: "Normal")
            case .relaxed: return String(localized: "Relaxed")
            }
        }
    }

    static let enabledKey = "AgentAutoSendEnabled"
    static let pauseKey = "AgentAutoSendPause"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var pause: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: pauseKey)
        return Pause(rawValue: stored)?.rawValue ?? Pause.normal.rawValue
    }

    private weak var engine: VoxOSEngine?
    private weak var recorderUIManager: RecorderUIManager?
    private var task: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "AgentAutoSend")

    init(engine: VoxOSEngine, recorderUIManager: RecorderUIManager) {
        self.engine = engine
        self.recorderUIManager = recorderUIManager
    }

    func startIfAgentMode() {
        guard ModeManager.shared.currentEffectiveConfiguration?.id == StarterModeCatalog.agentId else { return }
        startIfEnabled()
    }

    /// Arms the pause detector for the current hands-free recording: the Agent when its
    /// auto-send is on, dictation when "Stop Dictation When You Stop Talking" is on.
    func startIfEnabled() {
        cancel()
        guard let engine, engine.recordingState == .recording else { return }
        let isAgent = ModeManager.shared.currentEffectiveConfiguration?.id == StarterModeCatalog.agentId
        guard isAgent ? Self.isEnabled : DictationSend.stopWhenQuiet else { return }

        let pause = isAgent ? Self.pause : DictationSend.dictationPause
        task = Task { @MainActor [weak self] in
            var detector = AutoSendDetector(pause: pause, startedAt: Date())

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                // The sleep throws on cancellation and `try?` swallows it, so re-check here or a
                // cancelled detector runs one more full pass and can stop a freshly re-armed recording.
                guard !Task.isCancelled, let self, let engine = self.engine, engine.recordingState == .recording
                else { return }

                let now = Date()
                let level = engine.recorder.audioMeterSnapshot().averagePower
                let decision = detector.feed(
                    level: level,
                    transcript: engine.partialTranscript,
                    at: now)

                switch decision {
                case .keepListening:
                    if Int(now.timeIntervalSince(detector.startedAt) * 10) % 5 == 0 {
                        self.logger.info(
                            "auto-send: t=\(now.timeIntervalSince(detector.startedAt), format: .fixed(precision: 1), privacy: .public) level=\(level, format: .fixed(precision: 2), privacy: .public) floor=\(detector.noiseFloor ?? -1, format: .fixed(precision: 2), privacy: .public) heard=\(detector.heardSpeech, privacy: .public) transcript=\(engine.partialTranscript.count, privacy: .public)"
                        )
                    }
                    continue
                case .giveUp:
                    self.logger.notice("auto-send: no speech, closing")
                    self.task = nil
                    await self.recorderUIManager?.cancelRecording()
                    return
                case .send:
                    let elapsed = now.timeIntervalSince(detector.startedAt)
                    let floor = detector.noiseFloor ?? -1
                    let quiet = now.timeIntervalSince(detector.lastLoudAt)
                    let settled = now.timeIntervalSince(detector.transcriptChangedAt)
                    self.logger.notice(
                        "auto-send: sending after \(elapsed, format: .fixed(precision: 1), privacy: .public)s floor=\(floor, format: .fixed(precision: 2), privacy: .public) quiet=\(quiet, format: .fixed(precision: 1), privacy: .public)s transcriptSettled=\(settled, format: .fixed(precision: 1), privacy: .public)s"
                    )
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
