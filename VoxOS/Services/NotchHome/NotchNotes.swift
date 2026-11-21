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
        /// The plain text, for search.
        var text: String = ""
    }

    /// Where a dictation started from a note goes: the note, and where its caret was.
    struct DictationTarget: Equatable {
        let note: UUID
        let location: Int
        let started: Date
    }

    /// Newest first.
    @Published private(set) var notes: [Note] = []
    /// The note open in the editor; nil shows the list.
    @Published var openID: UUID?
    /// The search field is showing on the list (it takes the keyboard like an open note).
    @Published var searching = false
    @Published var query = ""
    /// A dictation started from a note, waiting for its text.
    private(set) var dictation: DictationTarget?
    /// The note pinned to the collapsed notch, and its first line, which the band shows.
    @Published private(set) var pinnedID: UUID?
    @Published private(set) var pinnedLine: String?

    /// A dictation is followed for this long; one cancelled or never finished then lapses, so a
    /// later dictation goes where the cursor is, as usual.
    static let dictationLifetime: TimeInterval = 120

    /// The list, filtered by the search when there is one.
    var shown: [Note] { Self.matching(notes, query: query) }

    private var loaded = false
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "NotchNotes")

    init(folder: URL? = nil, defaults: UserDefaults = .standard) {
        self.folder = folder ?? Self.defaultFolder
        self.defaults = defaults
        // Only the pinned note is read at launch, for the band; the list waits for the page.
        if let raw = defaults.string(forKey: DefaultsKeys.notchPinnedNote), let id = UUID(uuidString: raw),
            let text = Self.read(url(of: id))?.string
        {
            pinnedID = id
            pinnedLine = Self.title(from: text)
        }
    }

    private let defaults: UserDefaults

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
            let text = Self.read(url)?.string ?? ""
            return Note(id: id, title: Self.title(from: text), modified: modified, text: text)
        }
        .sorted { $0.modified > $1.modified }
    }

    /// A new note, empty or holding `text`, opened.
    @discardableResult
    func create(text: String = "") -> UUID {
        loadIfNeeded()
        let note = Note(id: UUID(), title: Self.untitled, modified: Date())
        notes.insert(note, at: 0)
        save(NSAttributedString(string: text, attributes: NotchNoteFormat.bodyAttributes), for: note.id)
        searching = false
        query = ""
        openID = note.id
        return note.id
    }

    /// Opens the card on the Notes page, pinned (from a drop, the menu bar, or a dictation).
    static func showInNotch() {
        DistributedNotificationCenter.default().postNotificationName(
            NotchHome.openRequest, object: NotchHomePage.notes.rawValue, userInfo: nil, deliverImmediately: true)
    }

    // MARK: Pinning

    /// Pins the note to the collapsed notch, in place of any other; pinned already, unpins it.
    func togglePin(_ id: UUID) {
        if pinnedID == id {
            pinnedID = nil
            pinnedLine = nil
            defaults.removeObject(forKey: DefaultsKeys.notchPinnedNote)
        } else {
            pinnedID = id
            pinnedLine = Self.title(from: text(of: id).string)
            defaults.set(id.uuidString, forKey: DefaultsKeys.notchPinnedNote)
        }
    }

    // MARK: Meetings

    static var savesMeetings: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.meetingNotesToNotes) }

    /// A meeting's notes as a note of their own: the title, when it was, the summary with its
    /// action items as a checklist, and the transcript under them.
    @discardableResult
    func saveMeeting(title: String, date: Date, notes summary: String?, transcript: String) -> UUID {
        loadIfNeeded()
        let id = create(text: "")
        openID = nil
        save(Self.meetingNote(title: title, date: date, notes: summary, transcript: transcript), for: id)
        return id
    }

    nonisolated static func meetingNote(title: String, date: Date, notes summary: String?, transcript: String)
        -> NSAttributedString
    {
        let result = NSMutableAttributedString()
        func add(_ text: String, font: NSFont, color: NSColor = NotchNoteFormat.textColor) {
            result.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: color]))
        }
        let heading = NSFont.systemFont(ofSize: NotchNoteFormat.headingSizes[2], weight: .bold)
        add(title, font: .systemFont(ofSize: NotchNoteFormat.headingSizes[0], weight: .bold))
        add(
            date.formatted(date: .abbreviated, time: .shortened), font: NotchNoteFormat.bodyFont,
            color: NotchNoteFormat.textColor.withAlphaComponent(0.6))
        add("", font: NotchNoteFormat.bodyFont)
        var inActions = false
        for line in NotchNoteFormat.fromMarkdown(summary ?? "").components(separatedBy: .newlines) {
            let label = line.trimmingCharacters(in: CharacterSet(charactersIn: ": ")).lowercased()
            if ["summary", "decisions", "action items"].contains(label) {
                inActions = label == "action items"
                add(line.trimmingCharacters(in: CharacterSet(charactersIn: ": ")), font: heading)
                continue
            }
            // An action item is something to tick off.
            let item = inActions && line.hasPrefix("• ") ? "\(NotchNoteFormat.unchecked) " + line.dropFirst(2) : line
            add(String(item), font: NotchNoteFormat.bodyFont)
        }
        if !transcript.isEmpty {
            add("", font: NotchNoteFormat.bodyFont)
            add(String(localized: "Transcript"), font: heading)
            add(transcript, font: NotchNoteFormat.bodyFont)
        }
        return result
    }

    // MARK: Dictation

    /// The next dictation goes into `note` at `location` instead of where the cursor is.
    func beginDictation(into note: UUID, at location: Int, now: Date = Date()) {
        dictation = DictationTarget(note: note, location: location, started: now)
    }

    /// The waiting dictation's target, taken (so it is used once), if it has not lapsed.
    func takeDictation(now: Date = Date()) -> DictationTarget? {
        defer { dictation = nil }
        guard let dictation, now.timeIntervalSince(dictation.started) <= Self.dictationLifetime else { return nil }
        return dictation
    }

    /// Dictated text into the note where its caret was, with a space between it and a word
    /// before it; the note is then shown in the card.
    func insert(_ dictated: String, into target: DictationTarget) {
        loadIfNeeded()
        guard notes.contains(where: { $0.id == target.note }) else { return }
        let text = NSMutableAttributedString(attributedString: self.text(of: target.note))
        let location = min(max(0, target.location), text.length)
        let piece = Self.joining(dictated, after: (text.string as NSString).substring(to: location))
        text.insert(NSAttributedString(string: piece, attributes: NotchNoteFormat.bodyAttributes), at: location)
        save(text, for: target.note)
        openID = target.note
        // After the recorder has gone: while it shows, the card stays hidden and would not pin.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Self.showInNotch() }
    }

    /// `dictated`, with a space in front when it follows a word.
    nonisolated static func joining(_ dictated: String, after before: String) -> String {
        let trimmed = dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = before.last, !last.isWhitespace else { return trimmed }
        return " " + trimmed
    }

    // MARK: Search

    /// Notes whose title or text holds every word of the query, ignoring case and accents.
    nonisolated static func matching(_ notes: [Note], query: String) -> [Note] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return notes }
        return notes.filter { note in
            let haystack = note.title + "\n" + note.text
            return words.allSatisfy {
                haystack.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
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
        if id == pinnedID { pinnedLine = title }
        if let index = notes.firstIndex(where: { $0.id == id }) {
            notes[index].title = title
            notes[index].text = text.string
            notes[index].modified = Date()
            // The note just edited moves to the top.
            if index != 0 { notes.insert(notes.remove(at: index), at: 0) }
        }
    }

    func delete(_ id: UUID) {
        if id == pinnedID { togglePin(id) }
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
