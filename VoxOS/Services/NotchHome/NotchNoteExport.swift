import AppKit
import UniformTypeIdentifiers

/// A note taken out of the notch: as Markdown, as a PDF, or as a new note in Apple Notes.
///
/// The conversions are pure, line by line, so they can be tested without a window: headings by
/// their size, bold and italic runs, and the note's own list markers turned into each format's.
enum NotchNoteExport {
    /// One line of a note, read for export.
    struct Line: Equatable {
        enum Kind: Equatable {
            case text
            case heading(Int)
            case bullet
            case numbered(String)
            case checklist(done: Bool)
        }

        var kind: Kind
        /// The line's runs after its marker: text, and whether each is bold or italic.
        var runs: [Run]

        struct Run: Equatable {
            var text: String
            var bold = false
            var italic = false
        }

        var plain: String { runs.map(\.text).joined() }
    }

    static func lines(of note: NSAttributedString) -> [Line] {
        let string = note.string as NSString
        var lines: [Line] = []
        string.enumerateSubstrings(
            in: NSRange(location: 0, length: string.length), options: [.byParagraphs, .substringNotRequired]
        ) { _, range, _, _ in
            let text = string.substring(with: range)
            let marker = NotchNoteFormat.markerLength(of: text)
            var kind = Line.Kind.text
            switch NotchNoteFormat.kind(of: text) {
            case .bullet: kind = .bullet
            case .checklist: kind = .checklist(done: text.hasPrefix(NotchNoteFormat.checked))
            case .numbered: kind = .numbered(String(text.prefix(marker)).trimmingCharacters(in: .whitespaces))
            case nil:
                if range.length > 0,
                    let font = note.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont,
                    let level = NotchNoteFormat.headingLevel(of: font)
                {
                    kind = .heading(level)
                }
            }
            var runs: [Line.Run] = []
            let body = NSRange(location: range.location + marker, length: range.length - marker)
            if body.length > 0 {
                note.enumerateAttribute(.font, in: body) { value, run, _ in
                    let traits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
                    runs.append(
                        Line.Run(
                            text: string.substring(with: run), bold: traits.contains(.bold),
                            italic: traits.contains(.italic)))
                }
            }
            lines.append(Line(kind: kind, runs: runs))
        }
        return lines
    }

    // MARK: Markdown

    static func markdown(from note: NSAttributedString) -> String {
        lines(of: note).map { line in
            switch line.kind {
            case .heading(let level):
                return String(repeating: "#", count: level) + " " + line.plain
            case .bullet: return "- " + emphasised(line.runs)
            case .numbered(let marker): return marker + " " + emphasised(line.runs)
            case .checklist(let done): return (done ? "- [x] " : "- [ ] ") + emphasised(line.runs)
            case .text: return emphasised(line.runs)
            }
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Runs with `**bold**` and `*italic*` around their words, the spaces outside the marks.
    private static func emphasised(_ runs: [Line.Run]) -> String {
        runs.map { run in
            let mark = (run.bold ? "**" : "") + (run.italic ? "*" : "")
            let core = run.text.trimmingCharacters(in: .whitespaces)
            guard !mark.isEmpty, !core.isEmpty else { return run.text }
            let lead = run.text.prefix { $0.isWhitespace }
            let trail = String(run.text.reversed().prefix { $0.isWhitespace })
            return lead + mark + core + String(mark.reversed()) + trail
        }
        .joined()
    }

    // MARK: HTML, for Apple Notes

    /// Apple Notes' own HTML: headings, lists grouped into `ul`/`ol`, a paragraph per line.
    static func html(from note: NSAttributedString) -> String {
        var html = ""
        var openList: String?
        func closeList() {
            if let open = openList { html += "</\(open)>" }
            openList = nil
        }
        for line in lines(of: note) {
            let list: String?
            switch line.kind {
            case .bullet: list = "ul"
            case .numbered: list = "ol"
            default: list = nil
            }
            if list != openList {
                closeList()
                if let list {
                    html += "<\(list)>"
                    openList = list
                }
            }
            let body = line.runs.map(htmlRun).joined()
            switch line.kind {
            case .heading(let level): html += "<h\(level)>\(escape(line.plain))</h\(level)>"
            case .bullet, .numbered: html += "<li>\(body)</li>"
            case .checklist(let done):
                let box = done ? NotchNoteFormat.checked : NotchNoteFormat.unchecked
                html += "<div>\(box) \(body)</div>"
            case .text: html += body.isEmpty ? "<div><br></div>" : "<div>\(body)</div>"
            }
        }
        closeList()
        return html
    }

    private static func htmlRun(_ run: Line.Run) -> String {
        var text = escape(run.text)
        if run.italic { text = "<i>\(text)</i>" }
        if run.bold { text = "<b>\(text)</b>" }
        return text
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // MARK: Saving

    /// A file name from the note's title, without characters a file name cannot hold.
    static func fileName(for title: String, extension ext: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned.isEmpty ? String(localized: "Note") : cleaned) + "." + ext
    }

    /// Asks where to save, then writes the note there as Markdown.
    @MainActor
    static func saveMarkdown(_ note: NSAttributedString, title: String) {
        guard let url = askWhereToSave(title: title, type: .init(filenameExtension: "md") ?? .plainText, ext: "md")
        else { return }
        try? markdown(from: note).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Asks where to save, then prints the note to a PDF there, dark text on white pages.
    @MainActor
    static func savePDF(_ note: NSAttributedString, title: String) {
        guard let url = askWhereToSave(title: title, type: .pdf, ext: "pdf") else { return }
        let info = NSPrintInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.topMargin = 54
        info.bottomMargin = 54
        info.leftMargin = 54
        info.rightMargin = 54
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        view.textStorage?.setAttributedString(printable(note))
        view.isVerticallyResizable = true
        view.sizeToFit()
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.run()
    }

    /// The note with its white text made dark, for paper.
    static func printable(_ note: NSAttributedString) -> NSAttributedString {
        let copy = NSMutableAttributedString(attributedString: note)
        copy.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 0, length: copy.length))
        return copy
    }

    @MainActor
    private static func askWhereToSave(title: String, type: UTType, ext: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = fileName(for: title, extension: ext)
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// A new note in Apple Notes with this one's text and formatting; true once Notes made it.
    static func sendToAppleNotes(_ note: NSAttributedString) async -> Bool {
        let body = AgentMusic.escape(html(from: note))
        let script = """
            tell application "Notes"
              try
                make new note at folder "Notes" of account "iCloud" with properties {body:"\(body)"}
              on error
                make new note at folder "Notes" of default account with properties {body:"\(body)"}
              end try
              return "ok"
            end tell
            """
        let result = await AgentAppleScript.runDetached(script, timeout: 20)
        return result["error"] == nil
    }
}
