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

    @Test func retryAfterReadsSecondsMinutesAndMilliseconds() {
        #expect(AIService.retryAfterSeconds(in: "Please try again in 7.5s.") == 7.5)
        #expect(AIService.retryAfterSeconds(in: "Rate limit reached. Please try again in 1m2.3s") == 62.3)
        #expect(AIService.retryAfterSeconds(in: "Please try again in 859.5ms") == 0.8595, "ms is not minutes")
        #expect(AIService.retryAfterSeconds(in: "slow down") == nil)
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
