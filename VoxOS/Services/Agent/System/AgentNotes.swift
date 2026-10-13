import Foundation

/// Read and search Apple Notes (creating a note is `notes_create`).
///
/// Scripts and parsing are pure so they can be tested without Notes. Results are capped because
/// they go straight back into the model's context: a long note must not blow a rate limit.
enum AgentNotes {
    static let maxResults = 10
    static let snippetLength = 140
    static let maxBodyLength = 6_000
    private static let field = "|||"
    private static let record = "<<<END>>>"

    static func searchScript(query: String, limit: Int) -> String {
        let limit = min(max(limit, 1), maxResults)
        return """
            tell application "Notes"
              set q to "\(AgentMusic.escape(query))"
              set hits to {}
              set matched to (every note whose name contains q)
              if (count of matched) is 0 then
                set matched to (every note whose plaintext contains q)
              end if
              set seen to {}
              repeat with n in matched
                set nid to id of n
                if seen does not contain nid then
                  set end of seen to nid
                  set noteText to plaintext of n
                  if (count of noteText) > \(snippetLength) then set noteText to text 1 thru \(snippetLength) of noteText
                  set end of hits to (name of n) & "\(field)" & noteText & "\(field)" & ((modification date of n) as string) & "\(record)"
                  if (count of hits) >= \(limit) then exit repeat
                end if
              end repeat
              set AppleScript's text item delimiters to ""
              return hits as string
            end tell
            """
    }

    /// An exact title match wins; otherwise the first note whose title contains the text.
    static func readScript(title: String) -> String {
        """
        tell application "Notes"
          set t to "\(AgentMusic.escape(title))"
          set found to (every note whose name is t)
          if (count of found) is 0 then set found to (every note whose name contains t)
          if (count of found) is 0 then return "NOT_FOUND"
          set n to item 1 of found
          return (name of n) & "\(field)" & (plaintext of n) & "\(field)" & ((modification date of n) as string)
        end tell
        """
    }

    static func parseSearch(_ raw: String) -> [[String: Any]] {
        raw.components(separatedBy: record).compactMap { chunk in
            let parts = chunk.components(separatedBy: field)
            guard parts.count >= 3,
                !parts[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return [
                "title": parts[0].trimmingCharacters(in: .whitespacesAndNewlines),
                "snippet": parts[1].replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                "modified": parts[2].trimmingCharacters(in: .whitespacesAndNewlines),
            ]
        }
    }

    static func parseRead(_ raw: String) -> [String: Any]? {
        guard raw != "NOT_FOUND" else { return nil }
        let parts = raw.components(separatedBy: field)
        guard parts.count >= 3 else { return nil }
        var body = parts[1...(parts.count - 2)].joined(separator: field)
        var truncated = false
        if body.count > maxBodyLength {
            body = String(body.prefix(maxBodyLength))
            truncated = true
        }
        return ["title": parts[0], "body": body, "modified": parts.last ?? "", "truncated": truncated]
    }

    /// Off the main thread: a body scan of a big library can take seconds.
    static func search(query: String, limit: Int) async -> [String: Any] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ["error": "query is required"] }
        let result = await AgentAppleScript.runDetached(searchScript(query: query, limit: limit))
        if let error = result["error"] { return ["error": error] }
        let notes = parseSearch(result["result"] as? String ?? "")
        return notes.isEmpty
            ? ["notes": [], "note": "No notes match \"\(query)\"."] : ["notes": notes, "count": notes.count]
    }

    static func read(title: String) async -> [String: Any] {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return ["error": "title is required"] }
        let result = await AgentAppleScript.runDetached(readScript(title: title))
        if let error = result["error"] { return ["error": error] }
        guard let note = parseRead(result["result"] as? String ?? "") else {
            return ["error": "No note titled \"\(title)\"."]
        }
        return note
    }
}
