import Foundation
import LLMkit

/// Decides when a chat request should move to a different provider, and which ones to try.
///
/// Failover is opt-in. The user lists the providers they are happy to send text and context to,
/// in order (`DefaultsKeys.aiFallbackProviders`); with an empty list nothing ever leaves the
/// provider the user chose, which keeps the "only the chosen LLM sees your text" invariant.
enum AIProviderFallback {
    /// Errors that say the provider is overloaded or unreachable, not that the request is wrong.
    /// A 400/401/403 would fail the same way anywhere, so those never fail over.
    static func isFailoverWorthy(_ error: LLMKitError) -> Bool {
        switch error {
        case .httpError(let status, _):
            return status == 408 || status == 429 || (500...599).contains(status)
        case .networkError, .timeout:
            return true
        default:
            return false
        }
    }

    /// The providers to try after `primary` fails, in the user's order.
    /// Skips the primary itself, duplicates, unknown names and providers that are not connected.
    static func candidates(
        primary: AIProvider, configuredOrder: [String], connected: [AIProvider]
    ) -> [AIProvider] {
        var seen: Set<AIProvider> = [primary]
        var result: [AIProvider] = []
        for name in configuredOrder {
            guard let provider = AIProvider(rawValue: name),
                connected.contains(provider),
                seen.insert(provider).inserted
            else { continue }
            result.append(provider)
        }
        return result
    }
}
