import Foundation

/// A model as listed by `GET /api/tags`, keeping the fields the setup screen needs that
/// LLMkit's `OllamaModel` does not expose (notably `remote_host` for cloud models).
struct OllamaInstalledModel: Identifiable, Equatable, Sendable {
    let name: String
    let sizeBytes: Int64
    let parameterSize: String?
    let isCloud: Bool

    var id: String { name }
}

/// One decoded line of the streamed `POST /api/pull` response.
struct OllamaPullProgress: Equatable, Sendable {
    let status: String
    let completed: Int64?
    let total: Int64?
    let error: String?

    /// Fraction of the current layer downloaded, or nil while Ollama is in a phase with no byte counts
    /// (manifest, verifying digest, writing manifest).
    var fraction: Double? {
        guard let completed, let total, total > 0 else { return nil }
        return min(max(Double(completed) / Double(total), 0), 1)
    }

    var isSuccess: Bool { status == "success" }
}

enum OllamaManagementError: Error, LocalizedError {
    case invalidURL
    case http(status: Int, message: String)
    case server(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "Invalid Ollama server URL")
        case .http(let status, let message):
            return message.isEmpty ? "HTTP \(status)" : "HTTP \(status): \(message)"
        case .server(let message):
            return message
        case .invalidResponse:
            return String(localized: "Invalid response from Ollama server")
        }
    }
}

enum OllamaManagement {
    /// Accepts what users actually type ("localhost:11434", "http://host:11434/") and returns a URL
    /// without a trailing slash so `appendingPathComponent("api/...")` builds the right path.
    static func normalizedBaseURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = OllamaService.defaultBaseURL }
        if !text.contains("://") { text = "http://" + text }
        while text.hasSuffix("/") { text.removeLast() }

        guard let components = URLComponents(string: text),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = components.host, !host.isEmpty
        else { return nil }
        return components.url
    }

    /// Cloud models are proxied to ollama.com: their tag ends in "cloud" (`gemma4:cloud`,
    /// `gpt-oss:120b-cloud`) and /api/tags reports a `remote_host`.
    static func isCloudModel(name: String, remoteHost: String? = nil) -> Bool {
        if let remoteHost, !remoteHost.isEmpty { return true }
        guard let tag = name.split(separator: ":", maxSplits: 1).dropFirst().first else { return false }
        let lowered = tag.lowercased()
        return lowered == "cloud" || lowered.hasSuffix("-cloud")
    }

    static func parseTags(_ data: Data) throws -> [OllamaInstalledModel] {
        let response = try JSONDecoder().decode(TagsResponse.self, from: data)
        return response.models.map { model in
            OllamaInstalledModel(
                name: model.name,
                sizeBytes: model.size ?? 0,
                parameterSize: model.details?.parameterSize,
                isCloud: isCloudModel(name: model.name, remoteHost: model.remoteHost)
            )
        }
    }

    static func parsePullLine(_ line: String) -> OllamaPullProgress? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8),
            let line = try? JSONDecoder().decode(PullLine.self, from: data)
        else { return nil }
        return OllamaPullProgress(
            status: line.status ?? "", completed: line.completed, total: line.total, error: line.error)
    }

    static func parseVersion(_ data: Data) -> String? {
        (try? JSONDecoder().decode(VersionResponse.self, from: data))?.version
    }

    /// Model names never contain whitespace; rejecting it early avoids a confusing server error.
    static func normalizedModelName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return nil
        }
        return trimmed
    }

    static func formattedSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private struct TagsResponse: Decodable {
        let models: [Tag]
    }

    private struct Tag: Decodable {
        let name: String
        let size: Int64?
        let remoteHost: String?
        let details: Details?

        enum CodingKeys: String, CodingKey {
            case name, size, details
            case remoteHost = "remote_host"
        }
    }

    private struct Details: Decodable {
        let parameterSize: String?

        enum CodingKeys: String, CodingKey {
            case parameterSize = "parameter_size"
        }
    }

    private struct PullLine: Decodable {
        let status: String?
        let completed: Int64?
        let total: Int64?
        let error: String?
    }

    private struct VersionResponse: Decodable {
        let version: String
    }
}

/// Server management calls (version, list, pull, delete). Kept separate from `OllamaService`, which
/// owns enhancement requests and the app-wide connection state.
struct OllamaManagementClient: Sendable {
    let baseURL: URL

    func version() async throws -> String {
        let data = try await send(path: "api/version", method: "GET", body: nil, timeout: 5)
        guard let version = OllamaManagement.parseVersion(data) else {
            throw OllamaManagementError.invalidResponse
        }
        return version
    }

    func installedModels() async throws -> [OllamaInstalledModel] {
        let data = try await send(path: "api/tags", method: "GET", body: nil, timeout: 10)
        return try OllamaManagement.parseTags(data)
    }

    func delete(model: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["model": model])
        _ = try await send(path: "api/delete", method: "DELETE", body: body, timeout: 30)
    }

    /// Streams pull progress. Cancelling the calling task stops the download on the client side;
    /// Ollama keeps the partial blobs and resumes them on the next pull of the same model.
    func pull(model: String, onProgress: @escaping @Sendable (OllamaPullProgress) async -> Void) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        // Layers can stall for a while between progress lines on slow links.
        request.timeoutInterval = 300

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var message = ""
            for try await line in bytes.lines {
                message += line
            }
            let parsed = OllamaManagement.parsePullLine(message)?.error ?? message
            throw OllamaManagementError.http(status: http.statusCode, message: parsed)
        }

        var succeeded = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let progress = OllamaManagement.parsePullLine(line) else { continue }
            if let error = progress.error {
                throw OllamaManagementError.server(error)
            }
            if progress.isSuccess { succeeded = true }
            await onProgress(progress)
        }
        if !succeeded {
            throw OllamaManagementError.invalidResponse
        }
    }

    private func send(path: String, method: String, body: Data?, timeout: TimeInterval) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OllamaManagementError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            let message = OllamaManagement.parsePullLine(text)?.error ?? text
            throw OllamaManagementError.http(
                status: http.statusCode, message: message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }
}
