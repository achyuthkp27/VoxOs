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
    /// Set once the mode is deleted, so leaving the editor does not write its shortcut back.
    @State private var didDeleteConfiguration = false
    /// `init` runs again on every parent body pass, so the editing baselines below are captured
    /// once, in `onAppear`, and this flag keeps a later appear from overwriting them.
    @State private var didCaptureBaseline = false
    /// The mode shortcut as it was when editing began. The recorder writes to `ShortcutStore` the
    /// moment a shortcut is captured, so Cancel has to put this back by hand.
    @State private var shortcutAtEditStart: Shortcut?
    @State private var shortcutWasClearedAtEditStart = false
    /// The mode shortcut as `ShortcutStore` holds it now, refreshed from its change notification
    /// so that recording or clearing a shortcut counts as an unsaved change.
    @State private var currentShortcut: Shortcut?
    /// What the draft would save once the form has finished normalising it on appear. Until it is
    /// captured, the draft is not treated as edited.
    @State private var baselineConfig: ModeConfig?

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
        // `State` keeps only the first value it is given, so this draft is used once per editor.
        _draft = State(initialValue: ModeConfigDraft(mode: mode, modeManager: modeManager))
    }

    private var unsavedChangesPresent: Bool {
        if promptEditorHasUnsavedChanges {
            return true
        }

        if didCaptureBaseline && currentShortcut != shortcutAtEditStart {
            return true
        }

        // Compare what would be saved with what would have been saved before any user edit, for
        // both new and existing modes. The baseline is taken after the form normalises the draft
        // on appear, so that normalisation does not read as a user edit.
        guard let baselineConfig else { return false }
        return !draft.makeConfig(mode: mode).isContentEqual(to: baselineConfig)
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
        .onAppear {
            prepareView()
            captureBaselineIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.shortcutDidChange)) { notification in
            let action = ShortcutAction.mode(draft.id)
            guard (notification.object as? ShortcutAction) == action else { return }
            currentShortcut = ShortcutStore.shortcut(for: action)
        }
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

    private func captureBaselineIfNeeded() {
        guard !didCaptureBaseline else { return }
        didCaptureBaseline = true

        let action = ShortcutAction.mode(draft.id)
        shortcutAtEditStart = ShortcutStore.shortcut(for: action)
        shortcutWasClearedAtEditStart = ShortcutStore.isShortcutCleared(for: action)
        currentShortcut = shortcutAtEditStart

        // The form normalises the draft in its own `onAppear` and `onChange` handlers (language
        // fallback, output rules, AI model), which run after this one. Waiting a few frames lets
        // them settle; nobody can edit a field that quickly, and until then nothing reads as dirty.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            baselineConfig = draft.makeConfig(mode: mode)
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
            // The mode is gone, and `removeConfiguration` already dropped its shortcut, so leaving
            // the editor must not write the shortcut back for an id that no longer exists.
            didDeleteConfiguration = true
            hasUnsavedChanges = false
            onDismiss()
        case .blockedDefault:
            break
        }
        return result
    }

    private func cleanupUnsavedShortcutIfNeeded() {
        guard !didSaveConfiguration, !didDeleteConfiguration, didCaptureBaseline else {
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
