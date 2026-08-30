import Foundation

enum StarterModeKind: String, CaseIterable, Identifiable {
    case clean
    case enhance
    case email
    case rewrite
    case assistant
    case agent

    var id: String { rawValue }
}

struct StarterModeTemplate: Identifiable {
    let kind: StarterModeKind
    let id: UUID
    let name: String
    let icon: ModeIcon
    let description: String
    let guidance: String
    let promptId: UUID?
    let outputMode: ModeOutputMode
    let usesAIEnhancement: Bool
    let useSelectedTextContext: Bool
    let useScreenCapture: Bool
    let isDefault: Bool

    var featureLabels: [String] {
        var labels = ["Transcription", "Realtime"]

        if usesAIEnhancement {
            labels.append("AI")
        } else {
            labels.append("No AI")
        }

        if outputMode == .respond {
            labels.append("Respond")
        } else {
            labels.append("Paste")
        }

        return labels
    }
}

enum StarterModeCatalog {
    static let templates: [StarterModeTemplate] = [
        StarterModeTemplate(
            kind: .clean,
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            name: "Dictation",
            icon: .symbol("mic.fill"),
            description: String(localized: "Fast transcription with no AI enhancement."),
            guidance: String(
                localized:
                    "Use this when you want the quickest possible voice-to-text result. It records with your configured transcription model and pastes the transcript as-is."
            ),
            promptId: nil,
            outputMode: .paste,
            usesAIEnhancement: false,
            useSelectedTextContext: false,
            useScreenCapture: false,
            isDefault: true
        ),
        StarterModeTemplate(
            kind: .enhance,
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            name: "Enhancement",
            icon: .symbol("sparkles"),
            description: "Clean up dictated text while preserving your meaning.",
            guidance:
                "Use this for everyday writing when you want grammar, flow, and light formatting improved before the result is pasted.",
            promptId: PromptTemplates.defaultPromptId,
            outputMode: .paste,
            usesAIEnhancement: true,
            useSelectedTextContext: true,
            useScreenCapture: true,
            isDefault: false
        ),
        StarterModeTemplate(
            kind: .email,
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
            name: "Email",
            icon: .symbol("envelope.fill"),
            description: "Turn a rough thought into a clean email.",
            guidance:
                "Use this after selecting relevant text or opening the related window. VoxOS uses that context to shape a clear email draft.",
            promptId: PromptTemplates.emailPromptId,
            outputMode: .paste,
            usesAIEnhancement: true,
            useSelectedTextContext: true,
            useScreenCapture: true,
            isDefault: false
        ),
        StarterModeTemplate(
            kind: .rewrite,
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!,
            name: "Rewrite",
            icon: .symbol("quote.bubble.fill"),
            description: "Rewrite selected or dictated text with better clarity.",
            guidance:
                "Use this when you have text selected and want a stronger version. The selected text is available as context for the rewrite.",
            promptId: PromptTemplates.rewritePromptId,
            outputMode: .paste,
            usesAIEnhancement: true,
            useSelectedTextContext: true,
            useScreenCapture: false,
            isDefault: false
        ),
        StarterModeTemplate(
            kind: .assistant,
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000005")!,
            name: "Assistant",
            icon: .symbol("bubble.left.and.bubble.right.fill"),
            description: "Ask a question and keep the answer in the recorder.",
            guidance:
                "Use this for answers, summaries, and follow-ups. Instead of pasting, VoxOS keeps the conversation inside the recorder.",
            promptId: PromptTemplates.assistantPromptId,
            outputMode: .respond,
            usesAIEnhancement: true,
            useSelectedTextContext: false,
            useScreenCapture: false,
            isDefault: false
        ),
        StarterModeTemplate(
            kind: .agent,
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000006")!,
            name: "Agent",
            icon: .symbol("wand.and.stars"),
            description: String(localized: "Speak an action and VoxOS does it on your Mac."),
            guidance: String(
                localized:
                    "Use this to act by voice: add calendar events, create reminders and notes, draft emails, find files, open apps and links. The result of each action is shown in the recorder."
            ),
            promptId: PromptTemplates.agentPromptId,
            outputMode: .respond,
            usesAIEnhancement: true,
            useSelectedTextContext: true,
            useScreenCapture: true,
            isDefault: false
        ),
    ]

    static var ids: Set<UUID> {
        Set(templates.map(\.id))
    }
}
