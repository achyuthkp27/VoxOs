import Foundation
import LLMkit

extension AIService {
    /// Chat completion with provider failover. LLMkit already retries 429/5xx/network failures
    /// three times with backoff inside every call, so this layer makes one attempt per provider.
    /// The exception is a 429 whose body names a wait ("try again in 12.3s", Groq): LLMkit's
    /// 1 s/2 s backoff cannot outlast that, so the named wait is honoured (capped) once here, so
    /// a burst of agent tool calls does not surface a raw HTTP error to the user. A timeout is
    /// never retried: the completion may already have run.
    ///
    /// If the provider is still failing and the user has listed fallback providers
    /// (`DefaultsKeys.aiFallbackProviders`), the same conversation is replayed on the next one.
    /// Tool calls are plain-text JSON (ADR 0001), so any provider can continue a run.
    func completeChat(
        provider: AIProvider,
        modelName: String?,
        messages: [ChatMessage],
        systemPrompt: String? = nil,
        timeout: TimeInterval = 30
    ) async throws -> String {
        let primaryError: LLMKitError
        do {
            return try await completeChatHonouringRetryAfter(
                provider: provider, modelName: modelName, messages: messages,
                systemPrompt: systemPrompt, timeout: timeout)
        } catch let error as LLMKitError {
            primaryError = error
        }

        guard AIProviderFallback.isFailoverWorthy(primaryError) else {
            throw Self.friendlyChatError(primaryError, modelName: modelName)
        }
        let fallbacks = AIProviderFallback.candidates(
            primary: provider,
            configuredOrder: UserDefaults.standard.stringArray(forKey: DefaultsKeys.aiFallbackProviders) ?? [],
            connected: connectedProviders)

        for fallback in fallbacks {
            // A cancelled run must not keep spending calls on the remaining providers.
            try Task.checkCancellation()
            if !AgentRunScope.isBackground {
                AgentProgress.set("\(provider.rawValue) is unavailable, trying \(fallback.rawValue)…")
            }
            do {
                // The fallback uses its own selected model: the primary's model name means nothing there.
                return try await completeChatHonouringRetryAfter(
                    provider: fallback, modelName: nil, messages: messages,
                    systemPrompt: systemPrompt, timeout: timeout)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Rate-limited, misconfigured or down: this fallback is no help, try the next one.
                continue
            }
        }
        // Every fallback failed too. The error worth showing is the chosen provider's: that is the
        // one the user can act on (wait out the limit, pick another model).
        throw Self.friendlyChatError(primaryError, modelName: modelName)
    }

    private func completeChatHonouringRetryAfter(
        provider: AIProvider,
        modelName: String?,
        messages: [ChatMessage],
        systemPrompt: String?,
        timeout: TimeInterval
    ) async throws -> String {
        var waitedForRetryAfter = false
        while true {
            do {
                return try await completeChatOnce(
                    provider: provider, modelName: modelName, messages: messages,
                    systemPrompt: systemPrompt, timeout: timeout)
            } catch let error as LLMKitError {
                guard !waitedForRetryAfter, let wait = Self.retryAfterDelay(for: error) else {
                    throw error
                }
                waitedForRetryAfter = true
                let showsProgress = !AgentRunScope.isBackground
                if showsProgress {
                    AgentProgress.set("Model is rate-limited, retrying in \(Int(wait.rounded(.up)))s…")
                }
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                if showsProgress { AgentProgress.set("Thinking…") }
            }
        }
    }

    /// Only a 429 that names its wait earns a retry here; everything else LLMkit already retried.
    static func retryAfterDelay(for error: LLMKitError) -> TimeInterval? {
        guard case .httpError(429, let message) = error,
            let seconds = Self.retryAfterSeconds(in: message)
        else {
            return nil
        }
        return min(seconds + 0.5, 8)
    }

    /// "try again in 7.5s", "in 1m2.3s", "in 859.5ms". The millisecond form used to be read as
    /// minutes, which turned a sub-second wait into the 8 s cap.
    static func retryAfterSeconds(in message: String) -> Double? {
        let lower = message.lowercased()
        guard let range = lower.range(of: "try again in ") else { return nil }
        let rest = lower[range.upperBound...]
        let token = rest.prefix { !$0.isWhitespace && $0 != "." || $0 == "." }
        let text = String(token).trimmingCharacters(in: CharacterSet(charactersIn: ".,"))
        if text.hasSuffix("ms"), let ms = Double(text.dropLast(2)) { return ms / 1000 }
        if let m = text.firstIndex(of: "m"), text.hasSuffix("s"),
            let minutes = Double(text[..<m]),
            let seconds = Double(text[text.index(after: m)..<text.index(before: text.endIndex)])
        {
            return minutes * 60 + seconds
        }
        if text.hasSuffix("s"), let seconds = Double(text.dropLast()) { return seconds }
        return nil
    }

    private static func friendlyChatError(_ error: LLMKitError, modelName: String?) -> Error {
        if case .httpError(let status, _) = error, status == 429 {
            return EnhancementError.customError(
                String(
                    format: String(
                        localized:
                            "%@ hit its per-minute token limit. Wait a moment, or pick a model with a higher limit in Modes → Agent."
                    ),
                    modelName ?? "The model"))
        }
        return error
    }

    private func completeChatOnce(
        provider: AIProvider,
        modelName: String?,
        messages: [ChatMessage],
        systemPrompt: String? = nil,
        timeout: TimeInterval = 30
    ) async throws -> String {
        let resolvedModel = modelName?.isEmpty == false ? modelName! : selectedModel(for: provider)

        let result: String
        switch provider {
        case .gemini:
            result = try await GeminiLLMClient.chatCompletion(
                apiKey: try chatAPIKey(for: provider, modelName: resolvedModel),
                model: resolvedModel,
                messages: messages,
                systemPrompt: systemPrompt,
                thinkingLevel: ReasoningConfig.geminiThinkingLevel(for: resolvedModel),
                store: false,
                timeout: timeout
            )
        case .anthropic:
            result = try await AnthropicLLMClient.chatCompletion(
                apiKey: try chatAPIKey(for: provider, modelName: resolvedModel),
                model: resolvedModel,
                messages: messages,
                systemPrompt: systemPrompt,
                timeout: timeout
            )
        case .custom:
            guard
                let customConfiguration = CustomAIProviderManager.shared.requestConfiguration(forModel: resolvedModel),
                let baseURL = URL(string: customConfiguration.baseURL)
            else {
                throw EnhancementError.notConfigured
            }
            result = try await OpenAILLMClient.chatCompletion(
                baseURL: baseURL,
                apiKey: customConfiguration.apiKey,
                model: customConfiguration.modelName,
                messages: messages,
                systemPrompt: systemPrompt,
                temperature: 0.3,
                timeout: timeout
            )
        case .voxOSRefine:
            throw EnhancementError.customError(
                String(localized: "VoxOS Refine only supports transcript cleanup.")
            )
        case .ollama:
            result = try await enhanceWithOllama(
                text: chatPrompt(from: messages),
                systemPrompt: systemPrompt ?? "",
                model: resolvedModel,
                timeout: timeout
            )
        case .localCLI:
            result = try await enhanceWithLocalCLI(
                systemPrompt: systemPrompt ?? "",
                userPrompt: chatPrompt(from: messages)
            )
        default:
            guard let baseURL = URL(string: provider.baseURL) else {
                throw EnhancementError.notConfigured
            }
            let temperature = resolvedModel.lowercased().hasPrefix("gpt-5") ? 1.0 : 0.3
            let reasoningEffort = ReasoningConfig.getReasoningParameter(
                for: provider,
                modelName: resolvedModel
            )
            let extraBody = ReasoningConfig.getExtraBodyParameters(
                for: provider,
                modelName: resolvedModel
            )
            result = try await OpenAILLMClient.chatCompletion(
                baseURL: baseURL,
                apiKey: try chatAPIKey(for: provider, modelName: resolvedModel),
                model: resolvedModel,
                messages: messages,
                systemPrompt: systemPrompt,
                temperature: temperature,
                reasoningEffort: reasoningEffort,
                extraBody: extraBody,
                timeout: timeout
            )
        }

        return AIEnhancementOutputFilter.filter(result)
    }

    private func chatAPIKey(for provider: AIProvider, modelName: String) throws -> String {
        if provider == .custom {
            guard let customConfiguration = CustomAIProviderManager.shared.requestConfiguration(forModel: modelName)
            else {
                throw EnhancementError.notConfigured
            }
            return customConfiguration.apiKey
        }

        guard let key = APIKeyManager.shared.getAPIKey(forProvider: provider.rawValue), !key.isEmpty else {
            throw EnhancementError.notConfigured
        }
        return key
    }

    private func chatPrompt(from messages: [ChatMessage]) -> String {
        let formattedMessages = messages.map { message in
            let label: String
            switch message.role {
            case "assistant":
                label = "assistant"
            case "user":
                label = "user"
            case "system":
                label = "system"
            default:
                label = "other"
            }
            return """
                <message role="\(label)">
                \(message.content)
                </message>
                """
        }
        .joined(separator: "\n\n")

        return """
            <conversation>
            \(formattedMessages)
            </conversation>
            """
    }
}
