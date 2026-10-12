import Foundation
import LLMkit
import Testing

@testable import VoxOS

/// Failover moves the user's text to another provider, so the risk is doing it when the user
/// did not ask for it or when it would not help. These pin both down.
@Suite
struct AIProviderFallbackTests {

    @Test func overloadAndOutageFailOver() {
        #expect(AIProviderFallback.isFailoverWorthy(.httpError(statusCode: 429, message: "slow down")))
        #expect(AIProviderFallback.isFailoverWorthy(.httpError(statusCode: 503, message: "high demand")))
        #expect(AIProviderFallback.isFailoverWorthy(.httpError(statusCode: 500, message: "")))
        #expect(AIProviderFallback.isFailoverWorthy(.httpError(statusCode: 408, message: "")))
    }

    @Test func requestAndKeyProblemsDoNotFailOver() {
        for status in [400, 401, 403, 404, 422] {
            #expect(!AIProviderFallback.isFailoverWorthy(.httpError(statusCode: status, message: "")), "\(status)")
        }
    }

    @Test func emptyListMeansNoFallback() {
        let result = AIProviderFallback.candidates(
            primary: .gemini, configuredOrder: [], connected: [.gemini, .groq, .openAI])
        #expect(result.isEmpty)
    }

    @Test func followsTheUsersOrder() {
        let result = AIProviderFallback.candidates(
            primary: .gemini, configuredOrder: ["OpenAI", "Groq"], connected: [.gemini, .groq, .openAI])
        #expect(result == [.openAI, .groq])
    }

    @Test func skipsPrimaryDuplicatesUnknownAndUnconnected() {
        let result = AIProviderFallback.candidates(
            primary: .gemini,
            configuredOrder: ["Gemini", "Groq", "Groq", "NotAProvider", "Anthropic"],
            connected: [.gemini, .groq])
        #expect(result == [.groq])
    }
}
