import Foundation

/// Web access that returns text to the agent rather than opening a browser: search results
/// from DuckDuckGo's HTML endpoint (no API key) and a stripped-text fetch of any page.
/// Ported from cursor-voice (MIT) WebSearch.
enum AgentWeb {
    struct SearchResult {
        let title: String
        let url: String
        let snippet: String
    }

    static func search(_ query: String, maxResults: Int = 6) async -> [String: Any] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")
        components?.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        guard !trimmed.isEmpty, let url = components?.url else { return ["error": "query is required"] }

        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Mozilla/5.0 (Macintosh; VoxOS)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            // Bound the work the same way fetch() does: an oversized response is never
            // worth parsing in full and would otherwise risk unbounded memory growth.
            let bounded = data.count > 3_000_000 ? data.prefix(3_000_000) : data
            let html = String(data: bounded, encoding: .utf8) ?? ""
            let results = parse(html: html).prefix(maxResults)
            return ["query": trimmed, "results": results.map { ["title": $0.title, "url": $0.url, "snippet": $0.snippet] }]
        } catch {
            return ["error": "search failed: \(error.localizedDescription)"]
        }
    }

    static func fetch(_ urlString: String, maxChars: Int = 4000) async -> [String: Any] {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https"
        else { return ["error": "invalid url: only http/https is supported"] }

        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Mozilla/5.0 (Macintosh; VoxOS)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Bound the work: a multi-megabyte page is never worth more than its first slice.
            let bounded = data.count > 3_000_000 ? data.prefix(3_000_000) : data
            let html = String(data: bounded, encoding: .utf8) ?? String(data: bounded, encoding: .isoLatin1) ?? ""
            let text = stripHTML(html)
            let clipped = text.count > maxChars ? String(text.prefix(maxChars)) + "\n…(truncated)" : text
            return ["url": urlString, "status": status, "text": clipped]
        } catch {
            return ["error": "fetch failed: \(error.localizedDescription)"]
        }
    }

    // MARK: - Parsing

    private static func parse(html: String) -> [SearchResult] {
        let anchors = matches(in: html, pattern: #"<a[^>]*class="[^"]*result__a[^"]*"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#)
        let snippets = matches(in: html, pattern: #"<a[^>]*class="[^"]*result__snippet[^"]*"[^>]*>(.*?)</a>"#)
        return anchors.enumerated().map { index, groups in
            SearchResult(
                title: stripHTML(groups.count > 2 ? groups[2] : ""),
                url: unwrapRedirect(groups.count > 1 ? groups[1] : ""),
                snippet: index < snippets.count ? stripHTML(snippets[index].count > 1 ? snippets[index][1] : "") : "")
        }
    }

    private static func unwrapRedirect(_ raw: String) -> String {
        guard let components = URLComponents(string: raw.hasPrefix("//") ? "https:" + raw : raw),
            let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value
        else { return raw }
        return target
    }

    private static func matches(in string: String, pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        let ns = string as NSString
        return regex.matches(in: string, range: NSRange(location: 0, length: ns.length)).map { match in
            (0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? "" : ns.substring(with: match.range(at: $0)) }
        }
    }

    static func stripHTML(_ html: String) -> String {
        var s = html
        for pattern in [#"<script[^>]*>.*?</script>"#, #"<style[^>]*>.*?</style>"#, #"<noscript[^>]*>.*?</noscript>"#] {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) {
                s = regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
            }
        }
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>") {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
        }
        let entities: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
            ("&nbsp;", " "), ("&hellip;", "…"), ("&#8217;", "'"), ("&#8220;", "\""), ("&#8221;", "\""), ("&mdash;", "—"),
        ]
        for (entity, replacement) in entities { s = s.replacingOccurrences(of: entity, with: replacement) }
        if let regex = try? NSRegularExpression(pattern: #"\s+"#) {
            s = regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: " ")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
