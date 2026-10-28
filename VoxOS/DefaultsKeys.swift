import Foundation

/// UserDefaults keys used across the app, so a mistyped key is a compile error instead of a
/// setting that silently reads back its zero value.
///
/// Defaults for these are registered in `AppDefaults.swift`; a key registered there with a
/// different value than the code assumes wins, so the two files are meant to be read together.
/// Domain-specific keys keep their own enums (`CleanupSettingsKeys`,
/// `RecorderDisplaySettingsKeys`, `UserDefaults.Keys`, `OnboardingStorageKeys`).
enum DefaultsKeys {
    // MARK: General
    static let hasCompletedOnboardingV2 = "hasCompletedOnboardingV2"
    static let dashboardDisplayName = "dashboardDisplayName"
    static let isExperimentalFeaturesEnabled = "isExperimentalFeaturesEnabled"
    static let modeTipDismissed = "ModeTipDismissed"
    static let hasPreparedOnboardingV2 = "hasPreparedOnboardingV2"
    static let isMenuBarOnly = "IsMenuBarOnly"

    // MARK: Clipboard & paste
    static let restoreClipboardAfterPaste = "restoreClipboardAfterPaste"
    static let clipboardRestoreDelay = "clipboardRestoreDelay"
    static let appendTrailingSpace = "AppendTrailingSpace"
    static let pasteMethod = "pasteMethod"
    static let useAppleScriptPaste = "useAppleScriptPaste"

    // MARK: Audio & media
    static let isSystemMuteEnabled = "isSystemMuteEnabled"
    static let isPauseMediaEnabled = "isPauseMediaEnabled"
    static let audioResumptionDelay = "audioResumptionDelay"
    static let audioPlaybackRate = "audioPlaybackRate"
    static let isSoundFeedbackEnabled = "isSoundFeedbackEnabled"
    static let lastUsedMicrophoneDeviceID = "lastUsedMicrophoneDeviceID"

    // MARK: Recording & transcription
    static let selectedLanguage = "SelectedLanguage"
    static let identifySpeakers = "IdentifySpeakers"
    static let isVADEnabled = "IsVADEnabled"
    static let isTextFormattingEnabled = "IsTextFormattingEnabled"
    static let recorderType = "RecorderType"
    /// "liquidGlass" or "solidBlack": the material of the notch recorder.
    static let notchMaterial = "NotchMaterial"
    /// Keep a slim, clickable tab under the notch between dictations.
    static let notchIdleTabEnabled = "NotchIdleTabEnabled"
    static let edgeHistoryEnabled = "EdgeHistoryEnabled"
    /// Claude Code in the notch: hooks installed in ~/.claude/settings.json and the bridge listening.
    static let claudeCodeEnabled = "ClaudeCodeEnabled"
    /// Permission requests can be allowed or denied from the notch.
    static let claudeCodeApprovalsEnabled = "ClaudeCodeApprovalsEnabled"
    /// The notch shows when a session is working and when it finishes.
    static let claudeCodeStatusEnabled = "ClaudeCodeStatusEnabled"
    /// The one-time "Show Claude Code in the notch?" card has been answered.
    static let claudeCodeOfferAnswered = "ClaudeCodeOfferAnswered"
    static let transcriptionPrompt = "TranscriptionPrompt"
    static let currentTranscriptionModel = "CurrentTranscriptionModel"
    static let currentModel = "CurrentModel"
    static let prewarmModelOnWake = "PrewarmModelOnWake"

    // MARK: Shortcuts
    static let primaryRecordingShortcut = "primaryRecordingShortcut"
    static let primaryRecordingShortcutMode = "primaryRecordingShortcutMode"
    static let secondaryRecordingShortcut = "secondaryRecordingShortcut"
    static let secondaryRecordingShortcutMode = "secondaryRecordingShortcutMode"
    static let isMiddleClickToggleEnabled = "isMiddleClickToggleEnabled"
    static let middleClickActivationDelay = "middleClickActivationDelay"
    static let appleFnUsageType = "AppleFnUsageType"

    // MARK: AI providers
    static let selectedAIProvider = "selectedAIProvider"
    static let customProviderModel = "customProviderModel"
    static let customProviderBaseURL = "customProviderBaseURL"
    static let ollamaBaseURL = "ollamaBaseURL"
    static let ollamaSelectedModel = "ollamaSelectedModel"
    static let openRouterModels = "openRouterModels"

    // MARK: Enhancement
    static let skipShortEnhancement = "SkipShortEnhancement"
    static let shortEnhancementWordThreshold = "ShortEnhancementWordThreshold"
    static let enhancementTimeoutSeconds = "EnhancementTimeoutSeconds"
    static let enhancementRetryOnTimeout = "EnhancementRetryOnTimeout"
    /// Ordered provider names (`AIProvider.rawValue`) the agent may fall back to when the chosen one is down.
    /// Superseded by `aiFallbackProvider`; read once to migrate its first entry.
    static let aiFallbackProviders = "AIFallbackProviders"
    /// Global main model (`AIProvider.rawValue` + model). When set, every mode uses it.
    static let aiMainProvider = "AIMainProvider"
    static let aiMainModel = "AIMainModel"
    /// Global Agent model; when set, Agent conversations use it instead of the main model.
    static let aiAgentProvider = "AIAgentProvider"
    static let aiAgentModel = "AIAgentModel"
    /// Global fallback model, tried when the main one is down or answers with nothing.
    static let aiFallbackProvider = "AIFallbackProvider"
    static let aiFallbackModel = "AIFallbackModel"
    static let aiFallbackMigrated = "AIFallbackMigrated"
    /// Close the Agent panel by itself after a request that only opened something.
    static let agentAutoCloseAfterOpen = "AgentAutoCloseAfterOpen"
    static let customPrompts = "customPrompts"
    static let selectedPromptId = "selectedPromptId"

    // MARK: Recording context
    static let useSelectedTextContext = "useSelectedTextContext"
    static let useClipboardContext = "useClipboardContext"
    static let useScreenCaptureContext = "useScreenCaptureContext"

    // MARK: Agent
    static let agentLearningLanguage = "agentLearningLanguage"
    static let agentLinearAPIToken = "AgentLinearAPIToken"

    // MARK: Dictionary
    static let vocabularySortMode = "vocabularySortMode"
    static let wordReplacementSortMode = "wordReplacementSortMode"
    static let dismissedCorrectionSuggestions = "dismissedCorrectionSuggestions"
    /// History → Review suggestions the user said were not mishearings.
    static let dismissedReviewSuggestions = "dismissedReviewSuggestions"

    // MARK: Licensing
    static let voxOSLicenseRequiresActivation = "VoxOSLicenseRequiresActivation"
    static let voxOSActivationsLimit = "VoxOSActivationsLimit"
    static let voxOSDeviceIdentifier = "VoxOSDeviceIdentifier"
}
