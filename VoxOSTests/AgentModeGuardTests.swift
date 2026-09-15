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
}
