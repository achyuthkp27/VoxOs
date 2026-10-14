import AppKit
import Foundation

enum StarterModeFactory {
    static let defaultTranscriptionModelName = "parakeet-ultra-0.6b"

    static func install(
        kinds: [StarterModeKind],
        provider: AIProvider,
        modelName: String?,
        transcriptionModelName: String = defaultTranscriptionModelName,
        isRealtimeTranscriptionEnabled: Bool = true,
        selectedLanguage: String = "auto",
        installedApps: [InstalledAppInfo] = []
    ) {
        let manager = ModeManager.shared
        let requestedKinds = Set(kinds)
        // No fallback to `InstalledApps.load()` here: that is a full /Applications scan with icon
        // loading, and this runs on the main thread on every onboarding step. Callers pass what
        // the warm-up store has scanned off-main and top the Email mode up afterwards with
        // `addMissingEmailAppTriggers`.
        let availableInstalledApps = requestedKinds.contains(.email) ? installedApps : []

        // Keep a starter mode the user already has rather than rebuilding it from the
        // catalogue: onboarding calls this on every experience step, and "Reset Onboarding"
        // would otherwise wipe every customised prompt, provider and context switch.
        let starterConfigs = StarterModeCatalog.templates
            .filter { requestedKinds.contains($0.kind) }
            .map { template in
                manager.configurations.first { $0.id == template.id }
                    ?? makeConfig(
                        from: template,
                        provider: provider,
                        modelName: modelName,
                        transcriptionModelName: transcriptionModelName,
                        isRealtimeTranscriptionEnabled: isRealtimeTranscriptionEnabled,
                        selectedLanguage: selectedLanguage,
                        installedApps: availableInstalledApps
                    )
            }

        let nonStarterConfigs = manager.configurations
            .filter { !StarterModeCatalog.ids.contains($0.id) }
            .map { config -> ModeConfig in
                var config = config
                if starterConfigs.contains(where: \.isDefault) {
                    config.isDefault = false
                }
                return config
            }

        manager.replaceConfigurations(starterConfigs + nonStarterConfigs)

        for config in starterConfigs where config.isDefault {
            ShortcutStore.removeShortcutStorage(for: .mode(config.id))
        }

        if let defaultConfig = starterConfigs.first(where: \.isDefault) {
            manager.setActiveConfiguration(defaultConfig)
        }
    }

    /// Onboarding installs the Email mode before the installed-app scan has finished, so its
    /// trigger group starts out with websites only. Called once the scan lands to add the mail
    /// apps that are installed. A group that already has apps is the user's, and is left alone.
    static func addMissingEmailAppTriggers(installedApps: [InstalledAppInfo]) {
        let manager = ModeManager.shared
        guard let template = StarterModeCatalog.templates.first(where: { $0.kind == .email }),
            var config = manager.configurations.first(where: { $0.id == template.id }),
            let groups = emailTriggerGroupsAddingApps(
                to: config.triggerGroups ?? [],
                installedApps: installedApps,
                existingAppBundleIds: Set(config.allAppConfigs.map(\.bundleIdentifier)),
                cleanURL: manager.cleanURL
            )
        else { return }

        config.triggerGroups = groups
        manager.updateConfiguration(config)
    }

    /// The groups with the email template's installed apps filled into its app-less group, or
    /// `nil` when there is nothing to add.
    static func emailTriggerGroupsAddingApps(
        to groups: [ModeTriggerGroup],
        installedApps: [InstalledAppInfo],
        existingAppBundleIds: Set<String>,
        cleanURL: (String) -> String
    ) -> [ModeTriggerGroup]? {
        guard !installedApps.isEmpty,
            let emailTemplate = TriggerTemplateCatalog.templates.first(where: { $0.id == emailTriggerTemplateId }),
            let groupIndex = groups.firstIndex(where: {
                $0.templateId == emailTriggerTemplateId && $0.appConfigs.isEmpty
            })
        else { return nil }

        let available = emailTemplate.availableGroup(
            installedApps: installedApps,
            existingAppBundleIds: existingAppBundleIds,
            existingWebsites: [],
            cleanURL: cleanURL
        )
        guard !available.appConfigs.isEmpty else { return nil }

        var groups = groups
        groups[groupIndex].appConfigs = available.appConfigs
        return groups
    }

    private static let emailTriggerTemplateId = "email"

    static func isInstalled(kind: StarterModeKind) -> Bool {
        guard let template = StarterModeCatalog.templates.first(where: { $0.kind == kind }) else {
            return false
        }

        return ModeManager.shared.configurations.contains { $0.id == template.id }
    }

    /// Adds the built-in "Agent" mode fully wired up (prompt, a working AI provider/model, and a
    /// Control+Option hold-to-talk shortcut) instead of leaving the user to assemble it by hand.
    /// Safe to call repeatedly: does nothing if the mode or its shortcut already exist.
    @discardableResult
    static func quickInstallAgent(snapshot: ModeFormWarmupSnapshot) -> Bool {
        guard let template = StarterModeCatalog.templates.first(where: { $0.kind == .agent }) else {
            return false
        }

        let manager = ModeManager.shared
        guard !manager.configurations.contains(where: { $0.id == template.id }) else {
            return false
        }

        let provider = snapshot.connectedAIProviders.first
        let modelName = provider.map { snapshot.selectedModel(for: $0) }

        let config = makeConfig(
            from: template,
            provider: provider ?? .ollama,
            modelName: modelName,
            transcriptionModelName: defaultTranscriptionModelName,
            isRealtimeTranscriptionEnabled: true,
            selectedLanguage: "auto",
            installedApps: []
        )

        manager.addConfiguration(config)

        ShortcutStore.seedShortcut(
            .modifierOnly(keyCode: nil, modifierFlags: [.control, .option]),
            for: .mode(template.id)
        )

        return true
    }

    private static func makeConfig(
        from template: StarterModeTemplate,
        provider: AIProvider,
        modelName: String?,
        transcriptionModelName: String,
        isRealtimeTranscriptionEnabled: Bool,
        selectedLanguage: String,
        installedApps: [InstalledAppInfo]
    ) -> ModeConfig {
        ModeConfig(
            id: template.id,
            name: template.name,
            icon: template.icon,
            appConfigs: nil,
            urlConfigs: nil,
            triggerGroups: triggerGroups(for: template.kind, installedApps: installedApps),
            isAIEnhancementEnabled: template.usesAIEnhancement,
            selectedPrompt: template.promptId?.uuidString,
            selectedTranscriptionModelName: transcriptionModelName,
            isRealtimeTranscriptionEnabled: isRealtimeTranscriptionEnabled,
            selectedLanguage: selectedLanguage,
            useClipboardContext: template.kind == .email,
            useSelectedTextContext: template.useSelectedTextContext,
            useScreenCapture: template.useScreenCapture,
            isTextFormattingEnabled: true,
            selectedAIProvider: template.usesAIEnhancement ? provider.rawValue : nil,
            selectedAIModel: template.usesAIEnhancement ? (modelName ?? provider.defaultModel) : nil,
            outputMode: template.outputMode,
            autoSendKey: .none,
            isEnabled: true,
            isDefault: template.isDefault
        )
    }

    private static func triggerGroups(
        for kind: StarterModeKind,
        installedApps: [InstalledAppInfo]
    ) -> [ModeTriggerGroup]? {
        guard kind == .email,
            let emailTemplate = TriggerTemplateCatalog.templates.first(where: { $0.id == emailTriggerTemplateId })
        else {
            return nil
        }

        let group = emailTemplate.availableGroup(
            installedApps: installedApps,
            existingAppBundleIds: [],
            existingWebsites: [],
            cleanURL: ModeManager.shared.cleanURL
        )

        return group.isEmpty ? nil : [group]
    }

}
