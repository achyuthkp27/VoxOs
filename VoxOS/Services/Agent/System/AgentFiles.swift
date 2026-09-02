import Foundation
import PDFKit

/// Read-mostly file tools. Move/rename is the only mutation; deletes are deliberately not
/// offered — the user can trash things from Finder.
/// Ported from cursor-voice (MIT) FileOps + DocReader.
enum AgentFiles {
    private static let maxChars = 12_000

    static func move(from: String, to: String) -> [String: Any] {
        let fm = FileManager.default
        let source = expand(from)
        var destination = expand(to)
        guard !from.isEmpty, !to.isEmpty else { return ["error": "from and to are required"] }
        guard fm.fileExists(atPath: source) else { return ["error": "source not found: \(source)"] }

        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: destination, isDirectory: &isDirectory), isDirectory.boolValue {
            destination = (destination as NSString).appendingPathComponent((source as NSString).lastPathComponent)
        }
        if fm.fileExists(atPath: destination) { return ["error": "destination already exists: \(destination)"] }
        do {
            try fm.moveItem(atPath: source, toPath: destination)
            return ["ok": true, "from": source, "to": destination]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    static func readPDF(path: String) -> [String: Any] {
        let p = expand(path)
        guard FileManager.default.fileExists(atPath: p) else { return ["error": "file not found: \(p)"] }
        guard let document = PDFDocument(url: URL(fileURLWithPath: p)) else {
            return ["error": "couldn't open as PDF (corrupt or not a PDF): \(p)"]
        }
        let text = document.string ?? ""
        if text.isEmpty {
            return [
                "ok": true, "path": p, "pages": document.pageCount, "chars": 0,
                "text": "(no extractable text — likely a scanned PDF; open it on screen and use read_screen instead)",
            ]
        }
        return ["ok": true, "path": p, "pages": document.pageCount, "chars": text.count, "text": clip(text)]
    }

    static func readFile(path: String) -> [String: Any] {
        let p = expand(path)
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: p, isDirectory: &isDirectory) else { return ["error": "file not found: \(p)"] }
        if isDirectory.boolValue {
            let entries = (try? fm.contentsOfDirectory(atPath: p)) ?? []
            return ["ok": true, "path": p, "is_directory": true, "entries": Array(entries.sorted().prefix(200))]
        }
        if let attrs = try? fm.attributesOfItem(atPath: p), let size = attrs[.size] as? Int, size > 5_000_000 {
            return ["error": "file too large (\(size) bytes) — only text files under 5 MB are read"]
        }
        if p.lowercased().hasSuffix(".pdf") { return readPDF(path: p) }
        guard let data = fm.contents(atPath: p) else { return ["error": "couldn't read file"] }
        if data.prefix(1024).contains(0) { return ["error": "looks like a binary file, not text: \(p)"] }
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        return ["ok": true, "path": p, "chars": text.count, "text": clip(text)]
    }

    private static func clip(_ text: String) -> String {
        text.count > maxChars ? String(text.prefix(maxChars)) + "\n…(truncated, \(text.count) chars total)" : text
    }

    private static func expand(_ path: String) -> String {
        (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
    }
}
