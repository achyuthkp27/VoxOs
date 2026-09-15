import Foundation
import LLMkit

extension AIService {
    /// Chat completion with retries for transient failures (429 rate limits, 5xx, network).
    /// Providers like Groq say "try again in 12.3s" in the 429 body; that wait is honoured
    /// (capped) so a burst of agent tool calls does not surface a raw HTTP error to the user.
    func completeChat(
        provider: AIProvider,
        modelName: String?,
        messages: [ChatMessage],
        systemPrompt: String? = nil,
        timeout: TimeInterval = 30
    ) async throws -> String {
        var attempt = 0
        var delay: TimeInterval = 1.5
        while true {
            do {
                return try await completeChatOnce(
                    provider: provider, modelName: modelName, messages: messages,
                    systemPrompt: systemPrompt, timeout: timeout)
            } catch let error as LLMKitError {
                attempt += 1
                guard attempt < 3, let wait = Self.retryDelay(for: error, fallback: delay) else {
                    throw Self.friendlyChatError(error, modelName: modelName)
                }
                if case .httpError(429, _) = error {
                    AgentProgress.set("Model is rate-limited, retrying in \(Int(wait.rounded(.up)))s…")
                } else {
                    AgentProgress.set("Connection hiccup, retrying…")
                }
                try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                AgentProgress.set("Thinking…")
                delay *= 2
            }
        }
    }

    private static func retryDelay(for error: LLMKitError, fallback: TimeInterval) -> TimeInterval? {
        switch error {
        case .httpError(let status, let message):
            if status == 429 {
                // "Please try again in 7.5s" / "in 1m2.3s"
                if let match = message.range(of: #"try again in ([0-9.]+)(m)?([0-9.]+)?s"#, options: .regularExpression) {
                    let text = String(message[match])
                    let numbers = text.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
                        .compactMap { Double($0) }
                    let seconds: Double
                    if text.contains("m"), numbers.count >= 2 { seconds = numbers[0] * 60 + numbers[1] }
                    else if text.contains("m"), numbers.count == 1 { seconds = numbers[0] * 60 }
                    else { seconds = numbers.first ?? fallback }
                    return min(max(seconds + 0.5, fallback), 8)
                }
                return fallback
            }
            return (500...599).contains(status) ? fallback : nil
        case .networkError, .timeout:
            return fallback
        default:
            return nil
        }
    }

    private static func friendlyChatError(_ error: LLMKitError, modelName: String?) -> Error {
        if case .httpError(let status, _) = error, status == 429 {
            return EnhancementError.customError(
                String(format: String(localized: "%@ hit its per-minute token limit. Wait a moment, or pick a model with a higher limit in Modes → Agent."),
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
