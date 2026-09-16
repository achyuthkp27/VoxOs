import FluidAudio
import Foundation
import OSLog

/// Works out who spoke when, so a recording with more than one voice can be transcribed as a
/// conversation rather than one undifferentiated block of text.
///
/// FluidAudio already ships the whole stack — segmentation, embedding and clustering — so this is
/// a thin adapter: it owns model loading and turns FluidAudio's segments into the plain
/// `SpeakerAttribution.SpeakerRange` values the attribution logic works with, which keeps that
/// logic free of any dependency on the ASR backend.
actor SpeakerDiarizationService {
    static let shared = SpeakerDiarizationService()

    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "SpeakerDiarization")
    private var manager: DiarizerManager?

    private init() {}

    enum DiarizationError: LocalizedError {
        case modelsUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .modelsUnavailable(let detail):
                return String(
                    format: String(localized: "Speaker models could not be loaded: %@"), detail)
            }
        }
    }

    /// Whether the models are already on disk, so callers can tell "will start a download" from
    /// "will just run" before committing the user to a wait.
    var isReady: Bool { manager != nil }

    /// Loads the diarization models, downloading them on first use.
    ///
    /// Kept separate from `speakerRanges` so a caller can front the download with its own
    /// progress rather than having a transcription mysteriously stall on a network fetch.
    func prepare() async throws {
        guard manager == nil else { return }
        do {
            let models = try await DiarizerModels.downloadIfNeeded()
            let manager = DiarizerManager()
            manager.initialize(models: consume models)
            self.manager = manager
            logger.notice("Speaker diarization models ready")
        } catch {
            logger.error("Could not load diarization models: \(error, privacy: .public)")
            throw DiarizationError.modelsUnavailable(error.localizedDescription)
        }
    }

    /// Speaker turns for mono 16 kHz samples, in the shape the attribution logic expects.
    ///
    /// Returns an empty array rather than throwing when the audio holds nothing it can segment:
    /// a single-speaker or silent recording is a normal outcome, not a failure, and the caller
    /// falls back to the plain transcript.
    func speakerRanges(
        samples: [Float],
        sampleRate: Int = 16_000
    ) async throws -> [SpeakerAttribution.SpeakerRange] {
        try await prepare()
        guard let manager else { return [] }

        let result = try manager.performCompleteDiarization(samples, sampleRate: sampleRate)
        return result.segments.map { segment in
            SpeakerAttribution.SpeakerRange(
                speakerId: segment.speakerId,
                startTime: TimeInterval(segment.startTimeSeconds),
                endTime: TimeInterval(segment.endTimeSeconds))
        }
    }

    /// Frees the models. Diarization is occasional, and these are large enough that holding them
    /// for a session that transcribed one meeting is not worth the resident memory.
    func cleanup() {
        manager?.cleanup()
        manager = nil
    }
}
