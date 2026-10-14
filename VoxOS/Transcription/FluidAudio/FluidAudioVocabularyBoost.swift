import FluidAudio
import Foundation
import os

/// Biases local Parakeet transcription toward the user's Dictionary words, so "Ollama" or
/// "Tumkur" comes out right without a replacement rule for every way it gets misheard.
///
/// FluidAudio runs a small CTC model (Parakeet CTC 110M, ~98 MB) over the same audio, spots the
/// Dictionary terms acoustically and rescores the transcript where they fit. That model is
/// downloaded once, in the background, the first time the Dictionary has words; until it is
/// ready transcription runs unboosted rather than waiting on the download.
actor FluidAudioVocabularyBoost {
    static let shared = FluidAudioVocabularyBoost()

    /// FluidAudio validates vocabularies up to ~230 terms; beyond that rescoring gets slow.
    static let maxTerms = 230
    /// Shorter terms misfire on common words ("or" → "VR"); FluidAudio's own floor is 3.
    static let minTermLength = 4

    private var models: CtcModels?
    private var loadTask: Task<Void, Never>?
    private var cachedSession: (terms: [String], session: VocabularyBoostingSession)?
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "VocabularyBoost")

    /// The Dictionary words worth boosting: long enough, deduplicated, capped.
    static func boostTerms(from words: [String]) -> [String] {
        var seen = Set<String>()
        var terms: [String] = []
        for word in words {
            let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= minTermLength, seen.insert(trimmed.lowercased()).inserted else { continue }
            terms.append(trimmed)
            if terms.count == maxTerms { break }
        }
        return terms
    }

    static func vocabulary(for terms: [String]) -> CustomVocabularyContext {
        CustomVocabularyContext(terms: terms.map { CustomVocabularyTerm(text: $0) }, minTermLength: minTermLength)
    }

    /// The CTC models, or nil while they are still downloading; asking starts the download.
    func modelsIfReady(for terms: [String]) -> CtcModels? {
        guard !terms.isEmpty, !ProcessIdentity.isTestHost else { return nil }
        if let models { return models }
        if loadTask == nil {
            loadTask = Task { [weak self] in
                do {
                    let loaded = try await CtcModels.downloadAndLoad()
                    await self?.finishLoading(loaded)
                } catch {
                    await self?.failLoading(error)
                }
            }
        }
        return nil
    }

    /// A rescoring session for these terms, reused while the Dictionary is unchanged.
    func session(for terms: [String]) async -> VocabularyBoostingSession? {
        guard let models = modelsIfReady(for: terms) else { return nil }
        if let cachedSession, cachedSession.terms == terms { return cachedSession.session }
        do {
            let session = try await VocabularyBoostingSession(vocabulary: Self.vocabulary(for: terms), ctcModels: models)
            cachedSession = (terms, session)
            return session
        } catch {
            logger.error("Vocabulary boosting unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func finishLoading(_ loaded: CtcModels) {
        models = loaded
        loadTask = nil
        logger.notice("Vocabulary boosting model ready")
    }

    private func failLoading(_ error: Error) {
        // Cleared so the next dictation tries again; transcription is never blocked on this.
        loadTask = nil
        logger.error("Vocabulary boosting model failed to load: \(error.localizedDescription, privacy: .public)")
    }
}
