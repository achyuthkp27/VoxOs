import Foundation
import SQLite3

/// Recent iMessage/SMS history straight from the user's own `~/Library/Messages/chat.db`.
/// Reading it needs Full Disk Access, so a permission failure is reported with a hint rather
/// than passed off as "no messages". SQL, date and body decoding are pure so they can be tested
/// without touching the real database.
enum AgentMessages {
    static let defaultLimit = 20
    static let maxLimit = 50
    static let maxTextLength = 300

    static let fullDiskAccessHint =
        "Give VoxOS Full Disk Access in System Settings > Privacy & Security > Full Disk Access, then try again."

    /// What the model sees when a message has neither `text` nor a decodable `attributedBody`.
    static let unsupportedBody = "(attachment or unsupported message)"

    static var databasePath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db").path
    }

    /// One joined row from `message` + `handle` + `chat`, before it becomes a tool result.
    struct Row {
        var text: String?
        var attributedBody: Data?
        var date: Int64
        var isFromMe: Bool
        var handle: String?
        var chatDisplayName: String?
        var chatIdentifier: String?
    }

    // MARK: - Pure helpers

    /// `message.date` is nanoseconds since 2001-01-01 on modern macOS but plain seconds in rows
    /// written by older releases; the magnitude tells them apart (seconds never reach 1e12).
    static func appleDate(_ raw: Int64) -> Date {
        let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    private static let whenFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    static func format(_ date: Date) -> String { whenFormatter.string(from: date) }

    /// Keeps each body short enough that fifty of them still fit comfortably in the model's context.
    static func clip(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxTextLength else { return trimmed }
        return String(trimmed.prefix(maxTextLength)) + "…"
    }

    /// Best-effort decode of the typedstream `attributedBody` blob that newer Messages builds use
    /// instead of `text`. The layout is: ... `NSString` marker, a few header bytes ending in `+`,
    /// then a length (one byte, or 0x81 + two little-endian bytes, or 0x82 + four), then UTF-8.
    /// Any inconsistency returns nil rather than guessing.
    static func text(fromAttributedBody data: Data) -> String? {
        let bytes = [UInt8](data)
        let marker = Array("NSString".utf8)
        guard bytes.count > marker.count else { return nil }
        guard
            let markerStart = (0...(bytes.count - marker.count)).first(where: { start in
                Array(bytes[start..<start + marker.count]) == marker
            })
        else { return nil }

        // The header between the marker and the length is short; the `+` (0x2B) byte closes it.
        let headerStart = markerStart + marker.count
        let headerEnd = min(bytes.count, headerStart + 8)
        guard headerStart < headerEnd,
            let plus = (headerStart..<headerEnd).first(where: { bytes[$0] == 0x2B })
        else { return nil }

        var cursor = plus + 1
        guard cursor < bytes.count else { return nil }
        var length = Int(bytes[cursor])
        cursor += 1
        switch length {
        case 0x81:
            guard cursor + 2 <= bytes.count else { return nil }
            length = Int(bytes[cursor]) | (Int(bytes[cursor + 1]) << 8)
            cursor += 2
        case 0x82:
            guard cursor + 4 <= bytes.count else { return nil }
            length =
                Int(bytes[cursor]) | (Int(bytes[cursor + 1]) << 8) | (Int(bytes[cursor + 2]) << 16)
                | (Int(bytes[cursor + 3]) << 24)
            cursor += 4
        default:
            break
        }
        guard length > 0, cursor + length <= bytes.count else { return nil }
        guard let text = String(bytes: bytes[cursor..<cursor + length], encoding: .utf8), !text.isEmpty else {
            return nil
        }
        return text
    }

    /// The body the model should read: `text` when present, else the decoded blob, else a marker.
    static func body(of row: Row) -> String {
        if let text = row.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        if let data = row.attributedBody, let text = text(fromAttributedBody: data) { return text }
        return unsupportedBody
    }

    static func item(from row: Row) -> [String: Any] {
        let handle = row.handle?.trimmingCharacters(in: .whitespaces) ?? ""
        let displayName = row.chatDisplayName?.trimmingCharacters(in: .whitespaces) ?? ""
        let identifier = row.chatIdentifier?.trimmingCharacters(in: .whitespaces) ?? ""
        let chat = !displayName.isEmpty ? displayName : (!identifier.isEmpty ? identifier : handle)
        return [
            "when": format(appleDate(row.date)),
            "from": row.isFromMe ? "me" : (handle.isEmpty ? "unknown" : handle),
            "chat": chat.isEmpty ? "unknown" : chat,
            "text": clip(body(of: row)),
        ]
    }

    /// `%` and `_` are LIKE wildcards; the user's text must match literally.
    static func likePattern(for contact: String) -> String {
        var escaped = ""
        for character in contact.lowercased() {
            if character == "%" || character == "_" || character == "\\" { escaped.append("\\") }
            escaped.append(character)
        }
        return "%\(escaped)%"
    }

    /// Newest first; the contact filter is bound, never interpolated. `GROUP BY` collapses the
    /// rare message that belongs to more than one chat so it is not listed twice.
    static let query = """
        SELECT m.text, m.attributedBody, m.date, m.is_from_me, h.id, c.display_name, c.chat_identifier
        FROM message m
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
        LEFT JOIN chat c ON c.ROWID = cmj.chat_id
        WHERE ?1 = ''
            OR lower(coalesce(h.id, '')) LIKE ?2 ESCAPE '\\'
            OR lower(coalesce(c.display_name, '')) LIKE ?2 ESCAPE '\\'
            OR lower(coalesce(c.chat_identifier, '')) LIKE ?2 ESCAPE '\\'
        GROUP BY m.ROWID
        ORDER BY m.date DESC
        LIMIT ?3
        """

    // MARK: - Tool entry point

    static func recent(contact: String, limit: Int) -> [String: Any] {
        let path = databasePath
        let contact = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = max(1, min(limit, maxLimit))

        guard FileManager.default.fileExists(atPath: path) else {
            return ["error": "Messages database not found at \(path)", "hint": fullDiskAccessHint]
        }
        // Without Full Disk Access `access(2)` fails with EPERM before SQLite ever sees the file.
        guard FileManager.default.isReadableFile(atPath: path) else {
            return ["error": "Messages database could not be opened (permission denied)", "hint": fullDiskAccessHint]
        }

        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        guard openResult == SQLITE_OK, let db else {
            return permissionError(openResult, db: db) ?? ["error": "could not open Messages database"]
        }

        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, query, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepareResult == SQLITE_OK, let statement else {
            return permissionError(prepareResult, db: db) ?? ["error": "Messages query failed: \(message(db))"]
        }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, contact, -1, transient)
        sqlite3_bind_text(statement, 2, likePattern(for: contact), -1, transient)
        sqlite3_bind_int(statement, 3, Int32(limit))

        var items: [[String: Any]] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                items.append(item(from: row(from: statement)))
                continue
            }
            if step == SQLITE_DONE { break }
            return permissionError(step, db: db) ?? ["error": "Messages query failed: \(message(db))"]
        }
        return ["messages": items, "count": items.count]
    }

    // MARK: - SQLite plumbing

    private static func row(from statement: OpaquePointer) -> Row {
        Row(
            text: column(statement, 0),
            attributedBody: blob(statement, 1),
            date: sqlite3_column_int64(statement, 2),
            isFromMe: sqlite3_column_int(statement, 3) != 0,
            handle: column(statement, 4),
            chatDisplayName: column(statement, 5),
            chatIdentifier: column(statement, 6))
    }

    private static func column(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private static func blob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let pointer = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: pointer, count: count)
    }

    private static func message(_ db: OpaquePointer?) -> String {
        guard let db, let text = sqlite3_errmsg(db) else { return "unknown SQLite error" }
        return String(cString: text)
    }

    /// Open, prepare and step can all surface a sandbox or TCC denial; each maps to the same hint.
    private static func permissionError(_ code: Int32, db: OpaquePointer?) -> [String: Any]? {
        let primary = code & 0xFF
        guard [SQLITE_CANTOPEN, SQLITE_PERM, SQLITE_AUTH, SQLITE_READONLY].contains(primary) else { return nil }
        return [
            "error": "Messages database could not be opened: \(message(db)) (code \(code))",
            "hint": fullDiskAccessHint,
        ]
    }
}
