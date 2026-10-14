import Foundation
import LLMkit
import Testing

@testable import VoxOS

/// The global main and fallback model move the user's text to models they picked, so the risk
/// is doing it when they did not pick one, or "falling back" to the very model that failed.
/// Serialized because every test reads and writes the same UserDefaults keys.
@Suite(.serialized)
struct AIModelRoutingTests {

    private static let keys = [
        DefaultsKeys.aiMainProvider, DefaultsKeys.aiMainModel, DefaultsKeys.aiFallbackProvider,
        DefaultsKeys.aiFallbackModel, DefaultsKeys.aiFallbackMigrated, DefaultsKeys.aiFallbackProviders,
    ]

    /// Runs `body` on clean keys, then puts back whatever was there.
    private func withCleanDefaults(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let saved = Self.keys.map { ($0, defaults.object(forKey: $0)) }
        Self.keys.forEach(defaults.removeObject(forKey:))
        body()
        for (key, value) in saved {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }

    @Test func nothingIsSetByDefault() {
        withCleanDefaults {
            #expect(AIModelRouting.main == nil, "with no main model every mode keeps its own")
            #expect(AIModelRouting.fallback == nil, "with no fallback text never leaves the chosen provider")
        }
    }

    @Test func choicesRoundTrip() {
        withCleanDefaults {
            AIModelRouting.main = AIModelChoice(provider: .groq, model: "openai/gpt-oss-120b")
            AIModelRouting.fallback = AIModelChoice(provider: .ollama, model: nil)
            #expect(AIModelRouting.main == AIModelChoice(provider: .groq, model: "openai/gpt-oss-120b"))
            #expect(AIModelRouting.fallback == AIModelChoice(provider: .ollama, model: nil))
            AIModelRouting.main = nil
            #expect(AIModelRouting.main == nil)
        }
    }

    @Test func voxOSRefineCannotBeMainOrFallback() {
        withCleanDefaults {
            #expect(!AIModelRouting.isEligible(.voxOSRefine), "Refine runs without the mode's prompt")
            UserDefaults.standard.set(AIProvider.voxOSRefine.rawValue, forKey: DefaultsKeys.aiMainProvider)
            #expect(AIModelRouting.main == nil)
        }
    }

    @Test func fallbackNeedsToBeSetConnectedAndDifferent() {
        withCleanDefaults {
            let resolve: (AIProvider) -> String = { "\($0.rawValue)-selected" }
            #expect(
                AIModelRouting.fallback(after: .groq, model: "a", connected: [.groq, .ollama], resolveModel: resolve)
                    == nil)

            AIModelRouting.fallback = AIModelChoice(provider: .ollama, model: "gemma4:cloud")
            #expect(
                AIModelRouting.fallback(after: .groq, model: "a", connected: [.groq], resolveModel: resolve) == nil,
                "a fallback that is not connected is skipped")
            let next = AIModelRouting.fallback(
                after: .groq, model: "a", connected: [.groq, .ollama], resolveModel: resolve)
            #expect(next?.provider == .ollama)
            #expect(next?.model == "gemma4:cloud")

            #expect(
                AIModelRouting.fallback(
                    after: .ollama, model: "gemma4:cloud", connected: [.ollama], resolveModel: resolve) == nil,
                "falling back to the model that just failed would only fail again")

            AIModelRouting.fallback = AIModelChoice(provider: .ollama, model: nil)
            #expect(
                AIModelRouting.fallback(after: .groq, model: nil, connected: [.groq, .ollama], resolveModel: resolve)?
                    .model == "Ollama-selected", "no model means the provider's selected model")
            #expect(
                AIModelRouting.fallback(
                    after: .ollama, model: "Ollama-selected", connected: [.ollama], resolveModel: resolve) == nil)
        }
    }

    @Test func sameProviderOtherModelIsAValidFallback() {
        withCleanDefaults {
            AIModelRouting.fallback = AIModelChoice(provider: .groq, model: "openai/gpt-oss-20b")
            let next = AIModelRouting.fallback(
                after: .groq, model: "openai/gpt-oss-120b", connected: [.groq], resolveModel: { _ in "" })
            #expect(next?.model == "openai/gpt-oss-20b")
        }
    }

    @Test func oldProviderListMigratesOnce() {
        withCleanDefaults {
            UserDefaults.standard.set(["Groq", "OpenAI"], forKey: DefaultsKeys.aiFallbackProviders)
            #expect(AIModelRouting.fallback == AIModelChoice(provider: .groq, model: nil))

            AIModelRouting.fallback = nil
            #expect(AIModelRouting.fallback == nil, "clearing the fallback must not bring the old list back")
        }
    }

    @Test func outagesFallBackButRequestErrorsDoNot() {
        for error in [
            EnhancementError.rateLimitExceeded, .serverError, .networkError, .timeout, .offline,
        ] {
            #expect(AIModelRouting.isFailoverWorthy(error), "\(error)")
        }
        for error in [EnhancementError.notConfigured, .invalidResponse, .customError("HTTP 401")] {
            #expect(!AIModelRouting.isFailoverWorthy(error), "\(error)")
        }
        #expect(AIModelRouting.isFailoverWorthy(LLMKitError.httpError(statusCode: 503, message: "")))
        #expect(!AIModelRouting.isFailoverWorthy(LLMKitError.httpError(statusCode: 401, message: "")))
        #expect(!AIModelRouting.isFailoverWorthy(CancellationError()))
    }
}
