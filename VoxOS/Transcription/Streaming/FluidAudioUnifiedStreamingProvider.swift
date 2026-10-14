import FluidAudio
import Foundation
import os

/// True streaming provider backed by FluidAudio's Parakeet Unified manager.
final class FluidAudioUnifiedStreamingProvider: StreamingTranscriptionProvider {
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "FluidAudioUnifiedStreaming")
    private var manager: StreamingUnifiedAsrManager?
    private var eventsContinuation: AsyncStream<StreamingTranscriptionEvent>.Continuation?

    private(set) var transcriptionEvents: AsyncStream<StreamingTranscriptionEvent>

    private let dictionaryWords: @MainActor () -> [String]

    init(dictionaryWords: @escaping @MainActor () -> [String] = { [] }) {
        self.dictionaryWords = dictionaryWords
        var continuation: AsyncStream<StreamingTranscriptionEvent>.Continuation!
        transcriptionEvents = AsyncStream { continuation = $0 }
        eventsContinuation = continuation
    }

    deinit {
        eventsContinuation?.finish()
    }

    func connect(model: any TranscriptionModel, language: String?) async throws {
        let manager = StreamingUnifiedAsrManager(
            config: FluidAudioModelManager.parakeetUnifiedStreamingConfig,
            encoderPrecision: FluidAudioModelManager.parakeetUnifiedPrecision
        )
        let continuation = eventsContinuation
        await manager.setPartialTranscriptCallback { partial in
            continuation?.yield(.partial(text: partial))
        }
        try await manager.loadModels(from: FluidAudioModelManager.parakeetUnifiedCacheDirectory())
        // Live text stays unboosted; FluidAudio rescores each finalized stretch toward the
        // Dictionary, so the committed text gets the corrections.
        let terms = FluidAudioVocabularyBoost.boostTerms(from: await MainActor.run { dictionaryWords() })
        if let models = await FluidAudioVocabularyBoost.shared.modelsIfReady(for: terms) {
            do {
                try await manager.configureVocabularyBoosting(
                    vocabulary: FluidAudioVocabularyBoost.vocabulary(for: terms), ctcModels: models)
            } catch {
                logger.error("Vocabulary boosting not configured: \(error.localizedDescription, privacy: .public)")
            }
        }
        self.manager = manager
        eventsContinuation?.yield(.sessionStarted)
        logger.notice("Parakeet Unified streaming started for \(model.displayName, privacy: .public)")
    }

    func sendAudioChunk(_ data: Data) async throws {
        guard let manager else {
            throw StreamingTranscriptionError.notConnected
        }

        guard !data.isEmpty else { return }

        guard let buffer = PCMAudioConverter.pcmBuffer(fromPCM16Data: data) else {
            throw StreamingTranscriptionError.audioConversionFailed
        }

        try await manager.appendAudio(buffer)
        try await manager.processBufferedAudio()
    }

    func commit() async throws {
        guard let manager else {
            throw StreamingTranscriptionError.notConnected
        }

        let finalText = try await manager.finish()
        let text = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = TextNormalizer.shared.normalizeSentence(text)
        eventsContinuation?.yield(.committed(text: normalized))
    }

    func disconnect() async {
        await manager?.cleanup()
        manager = nil
        eventsContinuation?.finish()
        logger.notice("Parakeet Unified streaming disconnected")
    }
}
