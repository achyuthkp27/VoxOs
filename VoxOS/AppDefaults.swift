import Foundation

enum CleanupSettingsKeys {
    static let isTranscriptionCleanupEnabled = "IsTranscriptionCleanupEnabled"
    static let transcriptionRetentionMinutes = "TranscriptionRetentionMinutes"
    static let isAudioCleanupEnabled = "IsAudioCleanupEnabled"
    static let audioRetentionPeriod = "AudioRetentionPeriod"
    static let lastAutomaticAudioCleanupDate = "AudioCleanupLastAutomaticCleanupDate"
}

enum RecorderDisplaySettingsKeys {
    static let showLiveTranscript = "ShowLiveTranscript"
}

enum AppDefaults {
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            // Onboarding & General
            DefaultsKeys.hasCompletedOnboardingV2: false,
            DefaultsKeys.hasPreparedOnboardingV2: false,

            // Clipboard
            DefaultsKeys.restoreClipboardAfterPaste: true,
            DefaultsKeys.clipboardRestoreDelay: 2.0,
            DefaultsKeys.useAppleScriptPaste: false,

            // Audio & Media
            DefaultsKeys.isSystemMuteEnabled: true,
            DefaultsKeys.audioResumptionDelay: 0.0,
            DefaultsKeys.isPauseMediaEnabled: false,
            CustomSoundManager.SoundType.start.builtInSoundKey: CustomSoundManager.SoundType.start.defaultBuiltInSound
                .rawValue,
            CustomSoundManager.SoundType.stop.builtInSoundKey: CustomSoundManager.SoundType.stop.defaultBuiltInSound
                .rawValue,

            // Recording & Transcription
            DefaultsKeys.isTextFormattingEnabled: true,
            DefaultsKeys.isVADEnabled: true,
            DefaultsKeys.selectedLanguage: "en",
            DefaultsKeys.appendTrailingSpace: true,
            DefaultsKeys.recorderType: "notch",
            RecorderDisplaySettingsKeys.showLiveTranscript: true,

            // Cleanup
            CleanupSettingsKeys.isTranscriptionCleanupEnabled: false,
            CleanupSettingsKeys.transcriptionRetentionMinutes: 1440,
            CleanupSettingsKeys.isAudioCleanupEnabled: false,
            CleanupSettingsKeys.audioRetentionPeriod: 7,

            // UI & Behavior
            // Menu bar only by default: VoxOS is driven by fn / ⌃⌃ and lives in the background.
            DefaultsKeys.isMenuBarOnly: true,
            // One-shot: LaunchAtLoginManager registers the login item on a machine's first run.
            LaunchAtLoginManager.didApplyDefaultKey: false,
            AppAppearancePreference.userDefaultsKey: AppAppearancePreference.system.rawValue,
            AppLanguagePreference.userDefaultsKey: AppLanguagePreference.systemValue,
            // Shortcuts
            DefaultsKeys.isMiddleClickToggleEnabled: false,
            DefaultsKeys.middleClickActivationDelay: 200,

            // Enhancement
            DefaultsKeys.skipShortEnhancement: true,
            DefaultsKeys.shortEnhancementWordThreshold: 3,
            DefaultsKeys.enhancementTimeoutSeconds: 7,
            DefaultsKeys.enhancementRetryOnTimeout: true,

            // Model
            DefaultsKeys.prewarmModelOnWake: true,

        ])

        PasteMethod.migrateLegacyUserDefaultIfNeeded()
    }
}
