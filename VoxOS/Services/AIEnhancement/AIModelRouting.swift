import Foundation
import LLMkit

/// One provider and, optionally, one of its models. A nil model means the provider's own
/// selected model (AI Models), resolved when the request is made.
struct AIModelChoice: Equatable {
    let provider: AIProvider
    let model: String?
}

/// The global main and fallback model (AI Models → Main & Fallback Model).
///
/// Both are opt-in. With no main model each mode keeps its own provider and model; with no
/// fallback nothing ever leaves the provider the user chose, which keeps the "only the chosen
/// LLM sees your text" invariant.
enum AIModelRouting {

    /// VoxOS Refine runs without a prompt, so it cannot stand in for a mode that has one.
    static func isEligible(_ provider: AIProvider) -> Bool {
        provider.supportsEnhancement && provider != .voxOSRefine
    }

    static var main: AIModelChoice? {
        get { read(providerKey: DefaultsKeys.aiMainProvider, modelKey: DefaultsKeys.aiMainModel) }
        set { write(newValue, providerKey: DefaultsKeys.aiMainProvider, modelKey: DefaultsKeys.aiMainModel) }
    }

    static var fallback: AIModelChoice? {
        get {
            migrateLegacyFallbackIfNeeded()
            return read(providerKey: DefaultsKeys.aiFallbackProvider, modelKey: DefaultsKeys.aiFallbackModel)
        }
        set {
            UserDefaults.standard.set(true, forKey: DefaultsKeys.aiFallbackMigrated)
            write(newValue, providerKey: DefaultsKeys.aiFallbackProvider, modelKey: DefaultsKeys.aiFallbackModel)
        }
    }

    /// The fallback to try after `provider`/`model` failed: nil when none is set, it is not
    /// connected, or it is the very model that just failed.
    static func fallback(
        after provider: AIProvider,
        model: String?,
        connected: [AIProvider],
        resolveModel: (AIProvider) -> String
    ) -> (provider: AIProvider, model: String)? {
        guard let choice = fallback, connected.contains(choice.provider) else { return nil }
        let fallbackModel = nonEmpty(choice.model) ?? resolveModel(choice.provider)
        let failedModel = nonEmpty(model) ?? resolveModel(provider)
        if choice.provider == provider, fallbackModel == failedModel { return nil }
        return (choice.provider, fallbackModel)
    }

    /// Errors that say the main provider is overloaded or unreachable. A 400/401/403 would
    /// fail the same way anywhere, so those never fall back. An empty reply is the caller's
    /// call, since it is not an error.
    static func isFailoverWorthy(_ error: Error) -> Bool {
        if let error = error as? LLMKitError { return AIProviderFallback.isFailoverWorthy(error) }
        guard let error = error as? EnhancementError else { return false }
        switch error {
        case .rateLimitExceeded, .serverError, .networkError, .timeout, .offline:
            return true
        default:
            return false
        }
    }

    /// The old setting was an ordered list of fallback providers; its first usable entry
    /// becomes the fallback (with that provider's selected model), once.
    private static func migrateLegacyFallbackIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: DefaultsKeys.aiFallbackMigrated) else { return }
        defaults.set(true, forKey: DefaultsKeys.aiFallbackMigrated)
        guard defaults.string(forKey: DefaultsKeys.aiFallbackProvider) == nil,
            let first = (defaults.stringArray(forKey: DefaultsKeys.aiFallbackProviders) ?? [])
                .compactMap(AIProvider.init(rawValue:))
                .first(where: isEligible)
        else { return }
        defaults.set(first.rawValue, forKey: DefaultsKeys.aiFallbackProvider)
    }

    private static func read(providerKey: String, modelKey: String) -> AIModelChoice? {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: providerKey), let provider = AIProvider(rawValue: raw),
            isEligible(provider)
        else { return nil }
        return AIModelChoice(provider: provider, model: nonEmpty(defaults.string(forKey: modelKey)))
    }

    private static func write(_ choice: AIModelChoice?, providerKey: String, modelKey: String) {
        let defaults = UserDefaults.standard
        if let choice {
            defaults.set(choice.provider.rawValue, forKey: providerKey)
            defaults.set(choice.model ?? "", forKey: modelKey)
        } else {
            defaults.removeObject(forKey: providerKey)
            defaults.removeObject(forKey: modelKey)
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
