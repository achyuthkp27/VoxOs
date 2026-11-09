import Foundation

/// Represents a single audio file in the transcription queue.
enum QueueItemStatus: Equatable {
    case pending
    case processing(phase: ProcessingPhase)
    case completed
    case failed(message: String)

    enum ProcessingPhase: String {
        case loading = "Loading model..."
        case processingAudio = "Processing audio..."
        case transcribing = "Transcribing..."
        case enhancing = "Enhancing..."
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed: return true
        default: return false
        }
    }
}

@MainActor
class AudioFileQueueItem: Identifiable, ObservableObject {
    let id = UUID()
    let url: URL
    let filename: String

    @Published var status: QueueItemStatus = .pending
    @Published var transcription: Transcription?
    /// Used for the AI step instead of the mode's prompt: Meeting Notes' summary.
    let prompt: CustomPrompt?
    /// The file is a temporary recording, deleted once its copy is saved with the transcript.
    let deletesSourceWhenDone: Bool
    /// The label History shows in place of the mode's name: "Meeting Notes" for a meeting.
    let label: String?

    init(url: URL, prompt: CustomPrompt? = nil, deletesSourceWhenDone: Bool = false, label: String? = nil) {
        self.url = url
        self.filename = url.lastPathComponent
        self.prompt = prompt
        self.deletesSourceWhenDone = deletesSourceWhenDone
        self.label = label
    }
}
