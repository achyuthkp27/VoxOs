import AVFoundation
import Foundation
import SwiftData
import SwiftUI
import os

struct AudioRetranscriptionResult {
    let transcription: Transcription
    let enhancementFailure: String?
}

@MainActor
class AudioTranscriptionService: ObservableObject {
    @Published var isTranscribing = false
    @Published var currentError: TranscriptionError?

    private let modelContext: ModelContext
    private let enhancementService: AIEnhancementService?
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "AudioTranscriptionService")
    private let serviceRegistry: TranscriptionServiceRegistry

    enum TranscriptionError: Error {
        case noAudioFile
        case transcriptionFailed
        case modelNotLoaded
        case invalidAudioFormat
    }

    init(modelContext: ModelContext, engine: VoxOSEngine) {
        self.modelContext = modelContext
        self.enhancementService = engine.enhancementService
        self.serviceRegistry = TranscriptionServiceRegistry(
            modelProvider: engine.whisperModelManager, modelsDirectory: engine.whisperModelManager.modelsDirectory,
            modelContext: modelContext)
    }

    init(
        modelContext: ModelContext, serviceRegistry: TranscriptionServiceRegistry,
        enhancementService: AIEnhancementService?
    ) {
        self.modelContext = modelContext
        self.enhancementService = enhancementService
        self.serviceRegistry = serviceRegistry
    }

    /// Pass `existing` to update that history row in place; without it a new row is created
    /// from a copy of the audio (the import path).
    func retranscribeAudio(
        from url: URL, using model: any TranscriptionModel, mode: ModeConfig? = nil, updating existing: Transcription? = nil
    ) async throws
        -> AudioRetranscriptionResult
    {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionError.noAudioFile
        }

        await MainActor.run {
            isTranscribing = true
        }

        do {
            let mode = mode ?? ModeManager.shared.currentEffectiveConfiguration
            let language = TranscriptionLanguageSupport.validLanguageOrFallback(
                mode?.selectedLanguage,
                for: model,
                realtimeEnabled: mode?.isRealtimeTranscriptionEnabled
            )
            let requestContext = TranscriptionRequestContext(
                language: language,
                prompt: model.provider == .whisper ? WhisperPrompt.resolvedPrompt(for: language) : nil
            )
            let modeName = (mode?.isEnabled == true) ? mode?.name : nil
            let modeEmoji = (mode?.isEnabled == true) ? mode?.icon.value : nil

            let transcriptionStart = Date()
            var text = try await serviceRegistry.transcribe(audioURL: url, model: model, context: requestContext)
            let transcriptionDuration = Date().timeIntervalSince(transcriptionStart)
            text = TranscriptionOutputFilter.filter(text)
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let formattingConfiguration = ModeRuntimeResolver.transcriptionFormattingConfiguration(mode: mode)

            if formattingConfiguration.isTextFormattingEnabled {
                text = ParagraphFormatter.format(text)
            }

            text = WordReplacementService.shared.applyReplacements(to: text, using: modelContext)
            let cleanedText = text

            let audioAsset = AVURLAsset(url: url)
            let duration = CMTimeGetSeconds(try await audioAsset.load(.duration))
            let recordingsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
                0
            ]
            .appendingPathComponent("com.achyuthkp.VoxOS")
            .appendingPathComponent("Recordings")

            // Updating an existing row reuses its audio; only a brand-new row needs its own copy.
            // Copying every time multiplied both history entries and audio files on each retry.
            let permanentURLString: String
            if let existing, let existingURL = existing.audioFileURL {
                permanentURLString = existingURL
            } else {
                let fileName = "retranscribed_\(UUID().uuidString).wav"
                let permanentURL = recordingsDirectory.appendingPathComponent(fileName)
                do {
                    try FileManager.default.copyItem(at: url, to: permanentURL)
                } catch {
                    logger.error("❌ Failed to create permanent copy of audio: \(error, privacy: .public)")
                    isTranscribing = false
                    throw error
                }
                permanentURLString = permanentURL.absoluteString
            }

            let originalText = cleanedText
            let enhancementConfiguration =
                enhancementService
                .flatMap { service in
                    service.getAIService().map { aiService in
                        ModeRuntimeResolver.currentEnhancementConfiguration(
                            mode: mode,
                            enhancementService: service,
                            aiService: aiService
                        )
                    }
                }

            var enhancedText: String?
            var aiEnhancementModelName: String?
            var promptName: String?
            var enhancementDuration: TimeInterval?
            var aiRequestSystemMessage: String?
            var aiRequestUserMessage: String?
            var enhancementFailure: String?

            if let enhancementService = enhancementService,
                let enhancementConfiguration,
                enhancementConfiguration.isEnabled,
                enhancementService.isConfigured(for: enhancementConfiguration)
            {
                do {
                    let enhancementResult = try await enhancementService.enhance(
                        text,
                        configuration: enhancementConfiguration
                    )
                    enhancedText = enhancementResult.text
                    aiEnhancementModelName =
                        enhancementConfiguration.modelName ?? enhancementConfiguration.provider?.defaultModel
                    promptName = enhancementResult.promptName
                    enhancementDuration = enhancementResult.duration
                    aiRequestSystemMessage = enhancementResult.systemMessage
                    aiRequestUserMessage = enhancementResult.userMessage
                } catch {
                    let failureDescription = EnhancementFailureFormatter.description(for: error)
                    enhancedText = EnhancementFailureFormatter.message(description: failureDescription)
                    enhancementFailure = failureDescription
                }
            }

            let transcription: Transcription
            if let existing {
                transcription = existing
                transcription.text = originalText
                transcription.enhancedText = enhancedText
                transcription.duration = duration
                transcription.transcriptionModelName = model.displayName
                transcription.aiEnhancementModelName = aiEnhancementModelName
                transcription.promptName = promptName
                transcription.transcriptionDuration = transcriptionDuration
                transcription.enhancementDuration = enhancementDuration
                transcription.aiRequestSystemMessage = aiRequestSystemMessage
                transcription.aiRequestUserMessage = aiRequestUserMessage
                transcription.modeName = modeName
                transcription.modeEmoji = modeEmoji
            } else {
                transcription = Transcription(
                    text: originalText,
                    duration: duration,
                    enhancedText: enhancedText,
                    audioFileURL: permanentURLString,
                    transcriptionModelName: model.displayName,
                    aiEnhancementModelName: aiEnhancementModelName,
                    promptName: promptName,
                    transcriptionDuration: transcriptionDuration,
                    enhancementDuration: enhancementDuration,
                    aiRequestSystemMessage: aiRequestSystemMessage,
                    aiRequestUserMessage: aiRequestUserMessage,
                    modeName: modeName,
                    modeEmoji: modeEmoji
                )
                modelContext.insert(transcription)
            }

            do {
                try modelContext.save()
                if existing == nil {
                    NotificationCenter.default.post(name: .transcriptionCreated, object: transcription)
                }
                NotificationCenter.default.post(name: .transcriptionCompleted, object: transcription)
            } catch {
                logger.error("❌ Failed to save transcription: \(error, privacy: .public)")
            }

            await MainActor.run {
                isTranscribing = false
            }

            return AudioRetranscriptionResult(
                transcription: transcription,
                enhancementFailure: enhancementFailure
            )
        } catch {
            logger.error("❌ Transcription failed: \(error, privacy: .public)")
            currentError = .transcriptionFailed
            isTranscribing = false
            throw error
        }
    }
}
