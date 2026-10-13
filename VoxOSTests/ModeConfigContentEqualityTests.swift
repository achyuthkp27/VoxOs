import Foundation
import Testing

@testable import VoxOS

/// `ModeConfig.==` is identity so lists keep tracking a mode while it is edited; the editor's
/// unsaved-changes check needs the field-by-field comparison instead. These pin the difference.
struct ModeConfigContentEqualityTests {

    private func config(id: UUID = UUID(), name: String = "Email") -> ModeConfig {
        ModeConfig(
            id: id, name: name, isAIEnhancementEnabled: true, selectedPrompt: "p",
            selectedTranscriptionModelName: "parakeet", useClipboardContext: true,
            selectedAIProvider: AIProvider.groq.rawValue, selectedAIModel: "m", outputMode: .paste)
    }

    @Test func identityEqualityIgnoresEditsButContentEqualityDoesNot() {
        let id = UUID()
        let saved = config(id: id)
        var edited = saved
        edited.name = "Work Email"

        #expect(saved == edited, "`==` is identity so selections survive a rename")
        #expect(!saved.isContentEqual(to: edited), "a rename is an unsaved change")
    }

    @Test func everyFieldCountsAsContent() {
        let id = UUID()
        let saved = config(id: id)

        var autoSend = saved
        autoSend.autoSendKey = .enter
        #expect(!saved.isContentEqual(to: autoSend))

        var triggers = saved
        triggers.triggerWords = ["email"]
        #expect(!saved.isContentEqual(to: triggers))

        var apps = saved
        apps.triggerGroups = [
            ModeTriggerGroup(
                name: "Email", appConfigs: [AppConfig(bundleIdentifier: "com.apple.mail", appName: "Mail")])
        ]
        #expect(!saved.isContentEqual(to: apps))

        var command = saved
        command.customCommand = ModeCustomCommand(command: "pbcopy")
        #expect(!saved.isContentEqual(to: command))
    }

    @Test func unchangedCopyIsContentEqual() {
        let saved = config()
        let copy = saved
        #expect(saved.isContentEqual(to: copy))
        #expect(saved.isContentEqual(to: saved))
    }

    @Test func differentModesWithTheSameFieldsAreNotContentEqual() {
        // The id is a persisted field too; two separate modes are never "the same edit".
        #expect(!config(id: UUID()).isContentEqual(to: config(id: UUID())))
    }
}
