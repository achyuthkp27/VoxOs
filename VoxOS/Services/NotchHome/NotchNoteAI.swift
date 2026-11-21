import Foundation

/// AI on a note: tidy it, summarise it, turn it into a checklist or an email draft, with the AI
/// provider and model of the mode in use. Only the note's text is sent, never the screen,
/// selection or clipboard.
@MainActor
enum NotchNoteAI {
    enum Action: CaseIterable, Identifiable {
        case tidy, summarise, checklist, email

        var id: Self { self }

        var title: String {
            switch self {
            case .tidy: return String(localized: "Tidy Up")
            case .summarise: return String(localized: "Summarise")
            case .checklist: return String(localized: "Make a Checklist")
            case .email: return String(localized: "Draft an Email")
            }
        }

        var symbol: String {
            switch self {
            case .tidy: return "wand.and.stars"
            case .summarise: return "text.append"
            case .checklist: return "checklist"
            case .email: return "envelope"
            }
        }

        /// Tidying and the checklist take the note's place; a summary goes on top and a draft
        /// under it, leaving the note as it was.
        var placement: Placement {
            switch self {
            case .tidy, .checklist: return .replace
            case .summarise: return .top
            case .email: return .bottom
            }
        }

        var instructions: String {
            let common =
                "Write in the note's own language. Use only what the note says; add nothing. Reply with the result only, no preamble."
            switch self {
            case .tidy:
                return
                    "Tidy this note: fix spelling and grammar, put related points together, use short paragraphs and \"- \" bullet points where it lists things. Keep every fact. \(common)"
            case .summarise:
                return "Summarise this note in two to four sentences. \(common)"
            case .checklist:
                return
                    "Turn this note into a checklist of the things to do, one per line, each starting with \"- [ ] \". Keep dates and names with their item. \(common)"
            case .email:
                return
                    "Draft a short, friendly email from this note: a subject line starting with \"Subject: \", then the body. \(common)"
            }
        }
    }

    enum Placement { case replace, top, bottom }

    enum Failure: LocalizedError {
        case notSetUp
        case empty

        var errorDescription: String? {
            switch self {
            case .notSetUp: return String(localized: "Set up an AI provider in Settings to use this.")
            case .empty: return String(localized: "The AI sent nothing back.")
            }
        }
    }

    /// The action's result as note text (lists with the note's own markers).
    static func run(_ action: Action, on text: String) async throws -> String {
        guard let engine = AgentEnvironment.engine, let service = engine.enhancementService,
            let ai = service.getAIService()
        else { throw Failure.notSetUp }
        let base = ModeRuntimeResolver.currentEnhancementConfiguration(enhancementService: service, aiService: ai)
        // VoxOS Refine only cleans dictation; it takes no instructions.
        guard base.provider != .voxOSRefine else { throw Failure.notSetUp }
        let configuration = EnhancementRuntimeConfiguration(
            mode: nil, isEnabled: true,
            prompt: CustomPrompt(title: action.title, promptText: action.instructions, useSystemInstructions: false),
            provider: base.provider, modelName: base.modelName, useClipboardContext: false,
            useSelectedTextContext: false, useScreenCaptureContext: false)
        guard service.isConfigured(for: configuration) else { throw Failure.notSetUp }
        let reply = try await service.enhance(text, configuration: configuration).text
        let result = NotchNoteFormat.fromMarkdown(reply)
        guard !result.isEmpty else { throw Failure.empty }
        return result
    }
}
