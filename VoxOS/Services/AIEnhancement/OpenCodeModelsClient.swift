import Foundation

/// OpenCode's model list, read from OpenCode rather than shipped in the app, since OpenCode adds
/// and retires models faster than VoxOS releases. The list is public; the key is sent anyway so
/// a workspace-specific list is used if OpenCode ever serves one.
enum OpenCodeModelsClient {
    static let modelsURL = URL(string: "https://opencode.ai/inference/v1/models")!

    /// OpenCode serves these families through other request formats (Anthropic messages, OpenAI
    /// responses, Gemini, structured decisions); VoxOS talks to its chat-completions endpoint only,
    /// so listing them would only produce request errors.
    static let otherFormatPrefixes = ["claude-", "gpt-", "gemini-", "grok-", "muse-", "jev-"]

    enum FetchError: LocalizedError {
        case rejected(status: Int, body: String)
        case unreadable

        var errorDescription: String? {
            switch self {
            case .rejected(let status, let body):
                return status == 401 || status == 403
                    ? "OpenCode rejected this API key." : "OpenCode returned HTTP \(status). \(body)"
            case .unreadable:
                return "OpenCode's model list could not be read."
            }
        }
    }

    /// Model IDs usable through chat completions, sorted with the free ones first.
    static func fetchModels(apiKey: String) async throws -> [String] {
        var request = URLRequest(url: modelsURL, timeoutInterval: 15)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw FetchError.rejected(status: status, body: String(decoding: data.prefix(300), as: UTF8.self))
        }
        guard let ids = modelIDs(from: data) else { throw FetchError.unreadable }
        return chatModels(from: ids)
    }

    /// Accepts both `{"data":[{"id":…}]}` (OpenAI style) and a bare `[{"id":…}]`.
    static func modelIDs(from data: Data) -> [String]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let entries = (json as? [String: Any])?["data"] as? [[String: Any]] ?? json as? [[String: Any]]
        return entries?.compactMap { $0["id"] as? String }
    }

    static func chatModels(from ids: [String]) -> [String] {
        let usable = Set(ids).filter { id in !otherFormatPrefixes.contains { id.lowercased().hasPrefix($0) } }
        return usable.sorted { lhs, rhs in
            isFree(lhs) != isFree(rhs) ? isFree(lhs) : lhs < rhs
        }
    }

    /// OpenCode marks free models with a "-free" suffix; Big Pickle is free under its own name.
    static func isFree(_ id: String) -> Bool {
        id.hasSuffix("-free") || id == "big-pickle"
    }
}
