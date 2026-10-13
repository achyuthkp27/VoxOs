import SwiftUI

struct ModeConfigEditorView: View {
    let mode: ConfigurationMode
    let modeManager: ModeManager
    let onDismiss: () -> Void
    /// Mirrors whether the draft (or an open prompt editor) differs from what is saved, so the
    /// owner of the side panel can ask before an outside click or Escape throws the edits away.
    @Binding var hasUnsavedChanges: Bool

    @EnvironmentObject private var enhancementService: AIEnhancementService
    @EnvironmentObject private var aiService: AIService
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @EnvironmentObject private var modeWarmupStore: ModeFormWarmupStore

    @State private var draft: ModeConfigDraft
    @State private var validationErrors: [ModeValidationError] = []
    @State private var showValidationAlert = false
    @State private var promptEditorMode: PromptEditorView.Mode?
    @State private var promptEditorID = UUID()
    @State private var promptEditorHasUnsavedChanges = false
    @State private var didSaveConfiguration = false
    /// The mode shortcut as it was when editing began. The recorder writes to `ShortcutStore` the
    /// moment a shortcut is captured, so Cancel has to put this back by hand.
    private let shortcutAtEditStart: Shortcut?
    private let shortcutWasClearedAtEditStart: Bool

    init(
        mode: ConfigurationMode,
        modeManager: ModeManager,
        hasUnsavedChanges: Binding<Bool> = .constant(false),
        onDismiss: @escaping () -> Void
    ) {
        self.mode = mode
        self.modeManager = modeManager
        self.onDismiss = onDismiss
        _hasUnsavedChanges = hasUnsavedChanges
        let draft = ModeConfigDraft(mode: mode, modeManager: modeManager)
        _draft = State(initialValue: draft)
        shortcutAtEditStart = ShortcutStore.shortcut(for: .mode(draft.id))
        shortcutWasClearedAtEditStart = ShortcutStore.isShortcutCleared(for: .mode(draft.id))
    }

    private var unsavedChangesPresent: Bool {
        if promptEditorHasUnsavedChanges {
            return true
        }

        switch mode {
        case .add:
            // Everything else in a new draft is inherited defaults; only what the user typed or
            // added counts as something worth protecting.
            return !draft.name.isEmpty || !draft.appConfigs.isEmpty || !draft.websiteConfigs.isEmpty
                || !draft.triggerGroups.isEmpty || !draft.triggerWords.isEmpty
        case .edit:
            // Compare what would be saved with what is saved, not the raw draft: the form
            // normalises the draft on appear, and that must not read as a user edit.
            guard let savedConfig = modeManager.getConfiguration(with: draft.id) else { return false }
            return draft.makeConfig(mode: mode) != savedConfig
        }
    }

    var body: some View {
        Group {
            if let promptEditorMode {
                PromptEditorView(
                    mode: promptEditorMode,
                    hasUnsavedChanges: $promptEditorHasUnsavedChanges,
                    onDismiss: closePromptEditor,
                    onSave: handlePromptSaved,
                    onDelete: handlePromptDeleted
                )
                .environmentObject(enhancementService)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(promptEditorID)
            } else {
                ModeConfigFormView(
                    mode: mode,
                    modeManager: modeManager,
                    draft: $draft,
                    validationErrors: $validationErrors,
                    showValidationAlert: $showValidationAlert,
                    onDismiss: onDismiss,
                    onSave: saveConfiguration,
                    onDelete: deleteConfiguration,
                    openPromptEditor: openPromptEditor
                )
            }
        }
        .onAppear(perform: prepareView)
        .onDisappear(perform: cleanupUnsavedShortcutIfNeeded)
        .onExitCommand(perform: handleExitCommand)
        .onChange(of: unsavedChangesPresent, initial: true) { _, newValue in
            hasUnsavedChanges = newValue
        }
    }

    private func openPromptEditor(mode: PromptEditorView.Mode) {
        promptEditorID = UUID()
        promptEditorMode = mode
    }

    private func closePromptEditor() {
        promptEditorHasUnsavedChanges = false
        promptEditorMode = nil
    }

    private func handlePromptSaved(_ prompt: CustomPrompt) {
        draft.selectedPromptId = prompt.id
        closePromptEditor()
    }

    private func handlePromptDeleted(_ prompt: CustomPrompt) {
        enhancementService.deletePrompt(prompt)
        if draft.selectedPromptId == prompt.id {
            draft.selectedPromptId = enhancementService.allPrompts.first?.id
        }
    }

    private func handleExitCommand() {
        if promptEditorMode != nil {
            // The prompt editor's own Back button confirms before discarding; Escape normally
            // reaches that button first, so this only closes when there is nothing to lose.
            if !promptEditorHasUnsavedChanges {
                closePromptEditor()
            }
        } else {
            onDismiss()
        }
    }

    private func prepareView() {
        modeWarmupStore.configure(
            aiService: aiService,
            enhancementService: enhancementService,
            transcriptionModelManager: transcriptionModelManager
        )

        let snapshot = modeWarmupStore.snapshot

        if case .add = mode {
            draft.applyAddModeDefaults(snapshot: snapshot)
            draft.inheritUsableTranscriptionModelSelection(from: snapshot)
        } else if let selectedModelName = draft.selectedTranscriptionModelName,
            !snapshot.hasUsableTranscriptionModel(named: selectedModelName)
        {
            draft.selectedTranscriptionModelName = nil
        }

        draft.ensurePromptSelection(firstPromptId: snapshot.firstPromptId)

        if let selectedModelName = draft.selectedTranscriptionModelName,
            let model = snapshot.transcriptionModel(named: selectedModelName)
        {
            draft.useCompatibleLanguage(for: model)
        }
    }

    private func saveConfiguration() {
        let config = draft.makeConfig(mode: mode)
        let validator = ModeValidator(modeManager: modeManager)
        validationErrors = validator.validateForSave(config: config, mode: mode)

        if !validationErrors.isEmpty {
            showValidationAlert = true
            return
        }

        switch mode {
        case .add:
            modeManager.addConfiguration(config)
        case .edit:
            modeManager.updateConfiguration(config)
        }

        didSaveConfiguration = true
        // Cleared before dismissing: the owner checks this flag synchronously and must not ask
        // about discarding edits that were just saved.
        hasUnsavedChanges = false
        onDismiss()
    }

    private func deleteConfiguration() -> ModeRemovalResult {
        let result = modeManager.removeConfiguration(with: draft.id)
        switch result {
        case .removed, .notFound:
            hasUnsavedChanges = false
            onDismiss()
        case .blockedDefault:
            break
        }
        return result
    }

    private func cleanupUnsavedShortcutIfNeeded() {
        guard !didSaveConfiguration else {
            return
        }

        let action = ShortcutAction.mode(draft.id)
        switch mode {
        case .add:
            ShortcutStore.removeShortcutStorage(for: action)
        case .edit:
            guard
                ShortcutStore.shortcut(for: action) != shortcutAtEditStart
                    || ShortcutStore.isShortcutCleared(for: action) != shortcutWasClearedAtEditStart
            else {
                return
            }

            if shortcutAtEditStart != nil || shortcutWasClearedAtEditStart {
                ShortcutStore.setShortcut(shortcutAtEditStart, for: action)
            } else {
                // Nothing was stored before, so leave nothing behind rather than a "cleared" marker.
                ShortcutStore.removeShortcutStorage(for: action)
            }
        }
    }
}
