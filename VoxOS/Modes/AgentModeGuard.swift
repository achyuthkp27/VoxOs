import Foundation

/// The Agent is built in, not an optional starter mode. This guarantees that on every launch,
/// after onboarding, and before ⌃⌃ opens it: the mode exists, is enabled, has its prompt, and
/// talks to a connected provider that can hold a conversation.
@MainActor
enum AgentModeGuard {

    nonisolated static var agentId: UUID { StarterModeCatalog.agentId }

    nonisolated static func isAgent(_ id: UUID) -> Bool { id == agentId }

    /// Pass `transcriptionModelManager` when available so a missing mode can be recreated;
    /// without it the guard still repairs an existing mode.
    @discardableResult
    static func ensure(
        enhancementService: AIEnhancementService?,
        transcriptionModelManager: TranscriptionModelManager?
    ) -> ModeConfig? {
        let manager = ModeManager.shared
        guard let enhancementService, let aiService = enhancementService.getAIService() else {
            return manager.getConfiguration(with: agentId)
        }

        let seeded = StarterModePromptSeeder.ensurePrompts(for: [.agent], in: enhancementService.customPrompts)
        if seeded.didChange {
            enhancementService.customPrompts = seeded.prompts
        }

        if manager.getConfiguration(with: agentId) == nil, let transcriptionModelManager {
            let snapshot = ModeFormWarmupSnapshot(
                aiService: aiService,
                enhancementService: enhancementService,
                transcriptionModelManager: transcriptionModelManager)
            StarterModeFactory.quickInstallAgent(snapshot: snapshot)
        }

        guard var agent = manager.getConfiguration(with: agentId) else { return nil }
        var repaired = repair(&agent, connected: aiService.connectedProviders) { aiService.selectedModel(for: $0) }
        // Auto-detect misreads short commands ("open Chrome" came out in Cyrillic): speak the
        // same language as the default dictation mode when that one is set.
        if let language = inheritedLanguage(agent: agent, defaultMode: manager.getDefaultConfiguration()) {
            agent.selectedLanguage = language
            repaired = true
        }
        if repaired {
            manager.updateConfiguration(agent)
        }
        return manager.getConfiguration(with: agentId)
    }

    /// The default mode's language, when the Agent is on auto-detect and the default is not.
    nonisolated static func inheritedLanguage(agent: ModeConfig, defaultMode: ModeConfig?) -> String? {
        let agentLanguage = agent.selectedLanguage ?? "auto"
        guard agentLanguage == "auto", let language = defaultMode?.selectedLanguage, language != "auto", !language.isEmpty
        else { return nil }
        return language
    }

    /// Pure repair step, separated for tests. Returns true when anything changed.
    static func repair(
        _ agent: inout ModeConfig,
        connected: [AIProvider],
        selectedModel: (AIProvider) -> String
    ) -> Bool {
        var changed = false

        if !agent.isEnabled {
            agent.isEnabled = true
            changed = true
        }
        if !agent.isAIEnhancementEnabled {
            agent.isAIEnhancementEnabled = true
            changed = true
        }
        if agent.selectedPrompt != PromptTemplates.agentPromptId.uuidString {
            agent.selectedPrompt = PromptTemplates.agentPromptId.uuidString
            changed = true
        }
        if agent.outputMode != .respond {
            agent.outputMode = .respond
            changed = true
        }

        // VoxOS Refine only cleans transcripts; it cannot run the tool loop.
        let usable = connected.filter { $0 != .voxOSRefine }
        let current = agent.selectedAIProvider.flatMap(AIProvider.init(rawValue:))
        if let replacement = usable.first, current.map({ !usable.contains($0) }) ?? true {
            agent.selectedAIProvider = replacement.rawValue
            agent.selectedAIModel = selectedModel(replacement)
            changed = true
        }
        return changed
    }
}
