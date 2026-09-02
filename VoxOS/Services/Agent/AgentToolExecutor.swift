import Foundation
import LLMkit

/// Provider-agnostic tool-calling loop. Works with every AIProvider (Gemini,
/// Anthropic, OpenAI, Groq, Ollama, Local CLI, ...) because it uses prompt-based
/// JSON tool calls instead of any vendor-specific function-calling API.
enum AgentToolExecutor {
    /// Presence of this marker in the system prompt is what turns the tool loop on.
    static let promptMarker = "VOXOS AGENT PROTOCOL"
    static let maxSteps = 14

    static func isAgentConversation(systemPrompt: String?) -> Bool {
        systemPrompt?.contains(promptMarker) == true
    }

    /// Extract a {"tool": ..., "args": {...}} call from a model reply, if present.
    static func parseToolCall(_ reply: String) -> (name: String, args: [String: Any])? {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard text.hasPrefix("{"),
            let data = text.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tool = obj["tool"] as? String
        else { return nil }
        return (tool, (obj["args"] as? [String: Any]) ?? [:])
    }

    /// Run the act/observe loop until the model produces a plain-text answer.
    static func runLoop(
        firstReply: String,
        priorMessages: [ChatMessage],
        systemPrompt: String?,
        provider: AIProvider?,
        modelName: String?,
        aiService: AIService,
        timeout: TimeInterval = 45
    ) async -> String {
        guard let provider else { return firstReply }

        var messages = priorMessages
        var reply = firstReply
        var steps = 0
        var executed: [String] = []

        while let call = parseToolCall(reply), steps < maxSteps {
            steps += 1
            let result = await AgentTools.execute(name: call.name, args: call.args)
            executed.append(call.name)

            let resultJSON =
                (try? JSONSerialization.data(withJSONObject: result))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"error\":\"unserializable result\"}"

            messages.append(.assistant(reply))
            messages.append(
                .user(
                    "TOOL_RESULT \(call.name): \(resultJSON)\n"
                        + "If the task needs another tool, reply with the next tool-call JSON only. "
                        + "Otherwise reply with one short plain-text sentence saying what was done."))

            do {
                reply = try await aiService.completeChat(
                    provider: provider,
                    modelName: modelName,
                    messages: messages,
                    systemPrompt: systemPrompt,
                    timeout: timeout
                )
            } catch {
                let done = executed.joined(separator: ", ")
                return "Ran \(done), but the follow-up model call failed: \(error.localizedDescription)"
            }
        }

        if parseToolCall(reply) != nil {
            return "Agent stopped after \(maxSteps) steps (ran: \(executed.joined(separator: ", ")))."
        }
        return reply
    }
}
