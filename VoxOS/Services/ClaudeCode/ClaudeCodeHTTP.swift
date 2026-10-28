import Foundation

/// The little HTTP/1.1 the bridge speaks: one POST per connection, a JSON body with a
/// Content-Length, and a response that closes the connection. Pure, so the parsing is tested
/// without a socket.
enum ClaudeCodeHTTP {
    struct Request: Equatable {
        let method: String
        let path: String
        /// Header names lowercased; a repeated header keeps its last value.
        let headers: [String: String]
        let body: Data
    }

    enum ParseResult: Equatable {
        case incomplete
        case invalid
        case complete(Request)
    }

    /// A PermissionRequest for Write carries the whole file, so the limit is generous; anything
    /// past it is refused rather than buffered.
    static let maxRequestBytes = 16 * 1024 * 1024
    private static let headerTerminator = Data("\r\n\r\n".utf8)

    static func parse(_ buffer: Data) -> ParseResult {
        guard let headerEnd = buffer.range(of: headerTerminator) else {
            return buffer.count > 64 * 1024 ? .invalid : .incomplete
        }
        guard let head = String(data: buffer[buffer.startIndex..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid
        }
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else { return .invalid }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // Chunked bodies are never sent by the CLI; refusing them keeps the parser this small.
        if headers["transfer-encoding"] != nil { return .invalid }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0, length <= maxRequestBytes else { return .invalid }

        let bodyStart = headerEnd.upperBound
        guard buffer.count - (bodyStart - buffer.startIndex) >= length else { return .incomplete }
        let body = buffer[bodyStart..<(bodyStart + length)]
        return .complete(
            Request(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: Data(body)))
    }

    static func response(status: Int, body: Data = Data(), contentType: String = "application/json") -> Data {
        var head = "HTTP/1.1 \(status) \(reason(status))\r\n"
        if !body.isEmpty { head += "Content-Type: \(contentType)\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    /// Only the loopback names the CLI is told to use. A web page that rebinds its own domain to
    /// 127.0.0.1 still sends that domain as Host, and is turned away here.
    static func isAllowedHost(_ host: String?, port: UInt16) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "127.0.0.1:\(port)" || host == "localhost:\(port)"
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        default: return "Error"
        }
    }
}
