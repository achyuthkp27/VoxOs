import AppKit
import Combine
import os

/// Notes written in the notch, kept on this Mac only: one rich-text (RTF) file per note in
/// `Application Support/com.achyuthkp.VoxOS/Notes`, named by the note's id. Nothing syncs.
///
/// The list is read the first time the Notes page shows, never at launch.
@MainActor
final class NotchNotes: ObservableObject {
    static let shared = NotchNotes()

    struct Note: Identifiable, Equatable {
        let id: UUID
        var title: String
        var modified: Date
    }

    /// Newest first.
    @Published private(set) var notes: [Note] = []
    /// The note open in the editor; nil shows the list.
    @Published var openID: UUID?

    private var loaded = false
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "NotchNotes")

    init(folder: URL? = nil) {
        self.folder = folder ?? Self.defaultFolder
    }

    let folder: URL

    static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.achyuthkp.VoxOS/Notes", isDirectory: true)
    }

    var openNote: Note? { notes.first { $0.id == openID } }

    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        notes = files.compactMap { url -> Note? in
            guard url.pathExtension == "rtf", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
            else { return nil }
            let modified =
                (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            return Note(id: id, title: Self.title(from: Self.read(url)?.string ?? ""), modified: modified)
        }
        .sorted { $0.modified > $1.modified }
    }

    /// A new, empty note, opened.
    @discardableResult
    func create() -> UUID {
        loadIfNeeded()
        let note = Note(id: UUID(), title: Self.untitled, modified: Date())
        notes.insert(note, at: 0)
        save(NSAttributedString(string: ""), for: note.id)
        openID = note.id
        return note.id
    }

    func text(of id: UUID) -> NSAttributedString {
        Self.read(url(of: id)) ?? NSAttributedString(string: "")
    }

    func save(_ text: NSAttributedString, for id: UUID) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try text.data(
                from: NSRange(location: 0, length: text.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            try data.write(to: url(of: id), options: .atomic)
        } catch {
            logger.error("Note not saved: \(error, privacy: .public)")
            return
        }
        let title = Self.title(from: text.string)
        if let index = notes.firstIndex(where: { $0.id == id }) {
            notes[index].title = title
            notes[index].modified = Date()
            // The note just edited moves to the top.
            if index != 0 { notes.insert(notes.remove(at: index), at: 0) }
        }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(of: id))
        notes.removeAll { $0.id == id }
        if openID == id { openID = nil }
    }

    /// The note's text on the clipboard: rich for apps that take it, plain for the rest.
    func copy(_ id: UUID) {
        let text = text(of: id)
        let board = NSPasteboard.general
        board.clearContents()
        if let rtf = try? text.data(
            from: NSRange(location: 0, length: text.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        {
            board.setData(rtf, forType: .rtf)
        }
        board.setString(text.string, forType: .string)
    }

    private func url(of id: UUID) -> URL {
        folder.appendingPathComponent(id.uuidString).appendingPathExtension("rtf")
    }

    private static func read(_ url: URL) -> NSAttributedString? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? NSAttributedString(
            data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
    }

    static var untitled: String { String(localized: "New Note") }

    /// The first line with words in it, without a list's marker, cut to a title's length.
    nonisolated static func title(from text: String) -> String {
        let line =
            text.components(separatedBy: .newlines)
            .map { NotchNoteFormat.strippingMarker($0).trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard !line.isEmpty else { return String(localized: "New Note") }
        return line.count > 60 ? String(line.prefix(59)) + "…" : line
    }

    /// "Edited 8:20 PM" today, "Edited Yesterday", or "Edited 12 Nov".
    nonisolated static func edited(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return String(localized: "Edited \(date.formatted(date: .omitted, time: .shortened))")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return String(localized: "Edited Yesterday")
        }
        return String(localized: "Edited \(date.formatted(.dateTime.day().month(.abbreviated)))")
    }
}
