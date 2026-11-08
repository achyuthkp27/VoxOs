import CoreFoundation
import Foundation

/// The settings a backup carries by key: every preference not already held by a named field of
/// `GeneralBackup`.
///
/// Named fields meant each new setting needed code in three places, so new settings were left out
/// and a restore brought back only part of a setup. Here a setting is one line in `keys`, and
/// `PreferencesBackupTests` fails when a key in `DefaultsKeys`, or one a view stores with
/// `@AppStorage`, is in none of `keys`, `coveredElsewhere` and `excluded`.
struct PreferencesBackup: Codable, Equatable {
    let values: [String: PreferenceValue]

    /// Backed up by key.
    static let keys: [String] = [
        // Pasting
        DefaultsKeys.appendTrailingSpace, DefaultsKeys.pasteMethod, PasteMethod.userDefaultsKey,
        DefaultsKeys.useAppleScriptPaste, WritingDestination.isEnabledKey,
        // Sound and recording
        DefaultsKeys.audioPlaybackRate, DefaultsKeys.isSoundFeedbackEnabled, DefaultsKeys.selectedLanguage,
        DefaultsKeys.identifySpeakers, DefaultsKeys.isVADEnabled, DefaultsKeys.edgeHistoryEnabled,
        DefaultsKeys.prewarmModelOnWake, DefaultsKeys.transcriptionPrompt,
        RecorderDisplaySettingsKeys.showLiveTranscript,
        DictationSend.stopWhenQuietKey, DictationSend.pressReturnKey,
        SystemAudioCaptureController.DefaultsKey.bufferEnabled, SystemAudioCaptureController.DefaultsKey.bufferSeconds,
        SystemAudioCaptureController.DefaultsKey.pasteAtCursor, SystemAudioCaptureController.DefaultsKey.saveToHistory,
        // Master switches; applied through `MasterSwitches` so the shortcuts and the notch follow
        DefaultsKeys.voiceAssistantEnabled, DefaultsKeys.notchMasterEnabled,
        // Notch
        DefaultsKeys.notchMaterial, DefaultsKeys.notchIdleTabEnabled, DefaultsKeys.notchHomeEnabled,
        DefaultsKeys.notchPageOrder, DefaultsKeys.notchDisabledPages, DefaultsKeys.notchDeviceAlertsEnabled,
        DefaultsKeys.notchHomeInFullScreen, DefaultsKeys.notchFollowsActiveDisplay, DefaultsKeys.notchHUDEnabled,
        DefaultsKeys.notchHiddenFromCapture, DefaultsKeys.notchDownloadsEnabled, DefaultsKeys.notchFocusEnabled,
        DefaultsKeys.notchMixerEnabled, DefaultsKeys.notchSoundOutputEnabled, DefaultsKeys.notchSoundInputEnabled,
        DefaultsKeys.notchMirrorEnabled, DefaultsKeys.notchClipboardEnabled, DefaultsKeys.notchLyricsEnabled,
        DefaultsKeys.notchRainEnabled, DefaultsKeys.notchUnreadEnabled, DefaultsKeys.notchPrivacyEnabled,
        DefaultsKeys.notchMeetingsEnabled, DefaultsKeys.notchMusicEnabled, DefaultsKeys.notchMusicBarsEnabled,
        DefaultsKeys.notchMusicBarsOnBattery,
        // Claude Code: how its cards behave, not whether its hooks are installed on this Mac
        DefaultsKeys.claudeCodeApprovalsEnabled, DefaultsKeys.claudeCodeStatusEnabled,
        DefaultsKeys.claudeCodeQuietInTerminal, DefaultsKeys.claudeCodeRepliesEnabled,
        DefaultsKeys.claudeCodeSpeaksReplies, DefaultsKeys.claudeCodeCIEnabled,
        // AI models and cleanup
        DefaultsKeys.selectedAIProvider, DefaultsKeys.customProviderModel, DefaultsKeys.customProviderBaseURL,
        DefaultsKeys.ollamaBaseURL, DefaultsKeys.ollamaSelectedModel, DefaultsKeys.aiMainProvider,
        DefaultsKeys.aiMainModel, DefaultsKeys.aiAgentProvider, DefaultsKeys.aiAgentModel,
        DefaultsKeys.aiFallbackProvider, DefaultsKeys.aiFallbackModel, DefaultsKeys.skipShortEnhancement,
        DefaultsKeys.shortEnhancementWordThreshold, DefaultsKeys.enhancementTimeoutSeconds,
        DefaultsKeys.enhancementRetryOnTimeout, DefaultsKeys.useSelectedTextContext, DefaultsKeys.useClipboardContext,
        DefaultsKeys.useScreenCaptureContext,
        // Agent
        AgentControlMode.userDefaultsKey, AgentAutoSend.enabledKey, AgentAutoSend.pauseKey, AgentAutoClose.enabledKey,
        DefaultsKeys.agentAutoCloseAfterOpen, AgentShell.allowRiskyKey, DefaultsKeys.agentLearningLanguage,
        // Dictionary and the rest
        DefaultsKeys.vocabularySortMode, DefaultsKeys.wordReplacementSortMode,
        DefaultsKeys.dismissedCorrectionSuggestions, DefaultsKeys.dismissedReviewSuggestions, DefaultsKeys.voiceSnippets,
        DefaultsKeys.dashboardDisplayName,
    ]

    /// Backed up by a named field of `GeneralBackup`, or by another backup category.
    static let coveredElsewhere: [String] = [
        DefaultsKeys.isMenuBarOnly, DefaultsKeys.restoreClipboardAfterPaste, DefaultsKeys.clipboardRestoreDelay,
        DefaultsKeys.isSystemMuteEnabled, DefaultsKeys.isPauseMediaEnabled, DefaultsKeys.audioResumptionDelay,
        DefaultsKeys.isTextFormattingEnabled, DefaultsKeys.recorderType, DefaultsKeys.isExperimentalFeaturesEnabled,
        DefaultsKeys.primaryRecordingShortcut, DefaultsKeys.primaryRecordingShortcutMode,
        DefaultsKeys.secondaryRecordingShortcut, DefaultsKeys.secondaryRecordingShortcutMode,
        DefaultsKeys.isMiddleClickToggleEnabled, DefaultsKeys.middleClickActivationDelay,
        DefaultsKeys.appSwitcherEnabled, DefaultsKeys.appSwitcherLetters, DefaultsKeys.windowSwitcherEnabled,
        DefaultsKeys.appSwitcherTrigger, DefaultsKeys.appSwitcherIgnoredApps, DefaultsKeys.appSwitcherSameLetterHides,
        DefaultsKeys.appSwitcherShowsLetters, AppAppearancePreference.userDefaultsKey,
        AppLanguagePreference.userDefaultsKey, CleanupSettingsKeys.isTranscriptionCleanupEnabled,
        CleanupSettingsKeys.transcriptionRetentionMinutes, CleanupSettingsKeys.isAudioCleanupEnabled,
        CleanupSettingsKeys.audioRetentionPeriod, DefaultsKeys.customPrompts,
    ]

    /// Never backed up: true only of this Mac or this install, secret, or a one-time note.
    static let excluded: [String] = [
        // Steps already taken on this install
        DefaultsKeys.hasCompletedOnboardingV2, DefaultsKeys.hasPreparedOnboardingV2, DefaultsKeys.modeTipDismissed,
        DefaultsKeys.claudeCodeOfferAnswered, DefaultsKeys.aiFallbackMigrated,
        // Hooks and files installed on this Mac; restoring the switch without them would lie
        DefaultsKeys.claudeCodeEnabled, DefaultsKeys.claudeCodeUsageEnabled, DefaultsKeys.claudeCodeOriginalStatusLine,
        DefaultsKeys.codexNotifyEnabled, DefaultsKeys.geminiHooksEnabled,
        // This Mac's devices, downloaded models and macOS's own settings
        DefaultsKeys.lastUsedMicrophoneDeviceID, AudioDeviceManager.singleMicrophoneSourceKey,
        DefaultsKeys.currentTranscriptionModel, DefaultsKeys.currentModel, DefaultsKeys.appleFnUsageType,
        // Caches, superseded keys and where a view was left
        DefaultsKeys.openRouterModels, DefaultsKeys.aiFallbackProviders, DefaultsKeys.selectedPromptId,
        DefaultsKeys.notchSoundSection, AppSidebar.collapsedKey,
        // Secrets and licensing
        DefaultsKeys.agentLinearAPIToken, DefaultsKeys.voxOSLicenseRequiresActivation,
        DefaultsKeys.voxOSActivationsLimit, DefaultsKeys.voxOSDeviceIdentifier,
    ]

    /// Applied through `MasterSwitches` rather than written, so what they switch follows.
    static let masterSwitchKeys: Set<String> = [DefaultsKeys.voiceAssistantEnabled, DefaultsKeys.notchMasterEnabled]

    /// What the user has set: values VoxOS only registers as defaults are left out, so a later
    /// change to a default still reaches a restored Mac.
    static func current(from setValues: [String: Any]) -> PreferencesBackup {
        var values: [String: PreferenceValue] = [:]
        for key in Set(keys) {
            if let value = setValues[key].flatMap(PreferenceValue.init) { values[key] = value }
        }
        return PreferencesBackup(values: values)
    }

    /// What is set in the app's own defaults now.
    static func current(_ defaults: UserDefaults = .standard) -> PreferencesBackup {
        let domain = Bundle.main.bundleIdentifier.flatMap(defaults.persistentDomain(forName:)) ?? [:]
        return current(from: domain)
    }

    /// Writes the backed-up values, except master switches, which are returned to be applied.
    /// Keys a newer VoxOS backed up but this one does not know are skipped.
    func apply(to defaults: UserDefaults = .standard) -> [String: Bool] {
        var switches: [String: Bool] = [:]
        let known = Set(Self.keys)
        for (key, value) in values where known.contains(key) {
            if Self.masterSwitchKeys.contains(key) {
                if case .bool(let isOn) = value { switches[key] = isOn }
            } else {
                defaults.set(value.propertyListValue, forKey: key)
            }
        }
        return switches
    }
}

/// One stored setting, in a form JSON can hold without losing whether it was a switch or a number.
enum PreferenceValue: Codable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case strings([String])
    case stringMap([String: String])

    init?(_ value: Any) {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .int(number.intValue)
            }
        case let string as String: self = .string(string)
        case let strings as [String]: self = .strings(strings)
        case let map as [String: String]: self = .stringMap(map)
        default: return nil
        }
    }

    var propertyListValue: Any {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        case .strings(let value): return value
        case .stringMap(let value): return value
        }
    }
}
