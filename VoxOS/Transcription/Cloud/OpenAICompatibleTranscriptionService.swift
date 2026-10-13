import Foundation

class OpenAICompatibleTranscriptionService {
    /// `audioData` is the file CloudTranscriptionService has already read; taking it avoids a
    /// second read of the recording just to build the multipart body.
    func transcribe(
        audioData: Data, fileName: String, model: CustomCloudModel, context: TranscriptionRequestContext
    ) async throws -> String {
        guard let url = URL(string: model.apiEndpoint) else {
            throw NSError(
                domain: "CustomWhisperTranscriptionService", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid API endpoint URL"])
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(model.apiKey)", forHTTPHeaderField: "Authorization")
        // Idle timeout; the default 60 s is too short for a slow self-hosted endpoint to start
        // answering a long upload, and without a bound a stalled one would hang the recording.
        request.timeoutInterval = 120

        let body = buildRequestBody(
            audioData: audioData, fileName: fileName, modelName: model.modelName, boundary: boundary, context: context)
        // Ephemeral session per request: the shared session persists Alt-Svc and upgrades
        // new connections to HTTP/3, but QUIC bulk uploads blackhole behind VPNs that drop
        // full-size UDP datagrams (e.g. GlobalProtect), timing out large audio uploads.
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.upload(for: request, from: body)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CloudTranscriptionError.networkError(URLError(.badServerResponse))
        }

        if !(200...299).contains(httpResponse.statusCode) {
            let errorMessage = String(data: data, encoding: .utf8) ?? "No error message"
            throw CloudTranscriptionError.apiRequestFailed(statusCode: httpResponse.statusCode, message: errorMessage)
        }

        do {
            return try JSONDecoder().decode(TranscriptionResponse.self, from: data).text
        } catch {
            throw CloudTranscriptionError.noTranscriptionReturned
        }
    }

    private func buildRequestBody(
        audioData: Data, fileName: String, modelName: String, boundary: String, context: TranscriptionRequestContext
    ) -> Data {
        let selectedLanguage = context.language ?? "auto"
        let crlf = "\r\n"
        var body = Data()

        func append(_ string: String) { body.append(string.data(using: .utf8)!) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\(crlf)")
            append("Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)")
            body.append(value.data(using: .utf8)!)
            append(crlf)
        }

        append("--\(boundary)\(crlf)")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\(crlf)")
        append("Content-Type: audio/wav\(crlf)\(crlf)")
        body.append(audioData)
        append(crlf)

        field("model", modelName)
        field("response_format", "json")
        field("temperature", "0")

        if selectedLanguage != "auto" && !selectedLanguage.isEmpty {
            field("language", selectedLanguage)
        }

        append("--\(boundary)--\(crlf)")
        return body
    }

    private struct TranscriptionResponse: Decodable {
        let text: String
        let language: String?
        let duration: Double?
    }
}
