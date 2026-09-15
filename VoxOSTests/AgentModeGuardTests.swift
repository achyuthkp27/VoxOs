import Foundation
import Testing

@testable import VoxOS

@MainActor
struct AgentModeGuardTests {

    private func brokenAgent(provider: AIProvider?) -> ModeConfig {
        var config = ModeConfig(
            id: StarterModeCatalog.agentId, name: "Agent", isAIEnhancementEnabled: false,
            selectedPrompt: nil, selectedAIProvider: provider?.rawValue, selectedAIModel: "old")
        config.isEnabled = false
        config.outputMode = .paste
        return config
    }

    @Test func repairsDisabledPromptlessAgent() {
        var agent = brokenAgent(provider: .groq)
        let changed = AgentModeGuard.repair(&agent, connected: [.groq]) { _ in "unused" }
        #expect(changed)
        #expect(agent.isEnabled)
        #expect(agent.isAIEnhancementEnabled)
        #expect(agent.selectedPrompt == PromptTemplates.agentPromptId.uuidString)
        #expect(agent.outputMode == .respond)
        #expect(agent.selectedAIProvider == AIProvider.groq.rawValue, "a connected provider is kept")
        #expect(agent.selectedAIModel == "old")
    }

    @Test func movesOffDisconnectedOrRefineProvider() {
        var agent = brokenAgent(provider: .voxOSRefine)
        _ = AgentModeGuard.repair(&agent, connected: [.voxOSRefine, .anthropic]) { _ in "claude-model" }
        #expect(agent.selectedAIProvider == AIProvider.anthropic.rawValue, "Refine cannot run the tool loop")
        #expect(agent.selectedAIModel == "claude-model")

        var orphan = brokenAgent(provider: .ollama)
        _ = AgentModeGuard.repair(&orphan, connected: [.groq]) { _ in "gpt" }
        #expect(orphan.selectedAIProvider == AIProvider.groq.rawValue)
    }

    @Test func healthyAgentIsUntouched() {
        var agent = brokenAgent(provider: .groq)
        _ = AgentModeGuard.repair(&agent, connected: [.groq]) { _ in "x" }
        #expect(!AgentModeGuard.repair(&agent, connected: [.groq]) { _ in "x" })
    }

    @Test func agentCannotBeDeleted() {
        #expect(AgentModeGuard.isAgent(StarterModeCatalog.agentId))
        #expect(!AgentModeGuard.isAgent(UUID()))
    }

    @Test func agentInheritsTheDefaultModesLanguage() {
        let agent = ModeConfig(id: StarterModeCatalog.agentId, name: "Agent", isAIEnhancementEnabled: true, selectedLanguage: "auto")
        let dictation = ModeConfig(name: "Dictation", isAIEnhancementEnabled: false, selectedLanguage: "en")
        #expect(AgentModeGuard.inheritedLanguage(agent: agent, defaultMode: dictation) == "en")

        let chosen = ModeConfig(id: StarterModeCatalog.agentId, name: "Agent", isAIEnhancementEnabled: true, selectedLanguage: "hi")
        #expect(AgentModeGuard.inheritedLanguage(agent: chosen, defaultMode: dictation) == nil, "a language the user picked is kept")

        let autoDefault = ModeConfig(name: "Dictation", isAIEnhancementEnabled: false, selectedLanguage: "auto")
        #expect(AgentModeGuard.inheritedLanguage(agent: agent, defaultMode: autoDefault) == nil)
    }
}
