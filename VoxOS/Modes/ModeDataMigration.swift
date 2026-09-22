import Foundation

extension ModeManager {
    func migratedModeConfigurationData(for configKey: String) -> Data? {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: configKey) {
            return data
        }

        guard let legacyData = defaults.data(forKey: LegacyModeDataKey.configurations) else {
            return nil
        }

        defaults.set(legacyData, forKey: configKey)
        return legacyData
    }

    func migrateLoadedModeConfigurationsIfNeeded() {
        var didChange = false

        for index in configurations.indices {
            var config = configurations[index]
            var changedConfig = false

            if config.selectedTranscriptionModelName == nil {
                config.selectedTranscriptionModelName = UserDefaults.standard.string(
                    forKey: DefaultsKeys.currentTranscriptionModel)
                changedConfig = true
            }

            if config.selectedLanguage == nil {
                config.selectedLanguage = UserDefaults.standard.string(forKey: DefaultsKeys.selectedLanguage) ?? "en"
                changedConfig = true
            }

            if config.selectedAIProvider == nil {
                config.selectedAIProvider = UserDefaults.standard.string(forKey: DefaultsKeys.selectedAIProvider)
                changedConfig = true
            }

            if config.selectedAIModel == nil,
                let provider = config.selectedAIProvider
            {
                config.selectedAIModel = UserDefaults.standard.string(forKey: "\(provider)SelectedModel")
                changedConfig = true
            }

            if config.isAIEnhancementEnabled && config.selectedPrompt == nil {
                config.selectedPrompt = UserDefaults.standard.string(forKey: DefaultsKeys.selectedPromptId)
                changedConfig = true
            }

            // The Rewrite starter mode shipped with `.paste`, which silently turned it into
            // "reword what I just said" — the selection never became the subject. Anyone who
            // installed it before the template was corrected still holds the broken value.
            //
            // Strictly one-shot. Every other rule here only fills a nil field, so re-running is
            // harmless; this one overwrites a populated, valid value, and Paste is a legitimate
            // choice the form offers. Without the flag it would silently undo that choice on
            // every launch, forever. Only promote a mode that can actually rewrite: the editor
            // forbids `.rewrite` without AI and with VoxOS Refine, which has no selection
            // context, so promoting one of those would paste the spoken instruction over the
            // selection.
            if !UserDefaults.standard.bool(forKey: Self.rewriteOutputModeMigrationKey),
                config.id == StarterModeCatalog.rewriteId,
                config.outputMode == .paste,
                config.isAIEnhancementEnabled,
                config.selectedAIProvider != AIProvider.voxOSRefine.rawValue
            {
                config.outputMode = .rewrite
                changedConfig = true
            }

            if changedConfig {
                configurations[index] = config
                didChange = true
            }
        }

        if didChange {
            saveConfigurations()
        }

        migrateLegacyShortcutStorageIfNeeded()
    }

    fileprivate static let rewriteOutputModeMigrationKey = "didMigrateRewriteOutputModeV1"

    /// Called at the end of every load, whether or not anything was decoded.
    func markOneShotModeMigrationsDone() {
        UserDefaults.standard.set(true, forKey: Self.rewriteOutputModeMigrationKey)
    }

    private func migrateLegacyShortcutStorageIfNeeded() {
        let defaults = UserDefaults.standard

        for config in configurations {
            let oldShortcutKey = "\(LegacyModeDataKey.shortcutPrefix)\(config.id.uuidString)"
            let newShortcutKey = ShortcutAction.mode(config.id).userDefaultsKey

            if defaults.object(forKey: newShortcutKey) == nil,
                let oldShortcutData = defaults.data(forKey: oldShortcutKey)
            {
                defaults.set(oldShortcutData, forKey: newShortcutKey)
            }

            let oldClearedKey = "\(oldShortcutKey)_cleared"
            let newClearedKey = "\(newShortcutKey)_cleared"
            if defaults.object(forKey: newClearedKey) == nil,
                defaults.object(forKey: oldClearedKey) != nil
            {
                defaults.set(defaults.bool(forKey: oldClearedKey), forKey: newClearedKey)
            }
        }
    }
}

private enum LegacyModeDataKey {
    static let configurations = "powerModeConfigurationsV2"
    static let shortcutPrefix = "Shortcut_powerMode_"
}
