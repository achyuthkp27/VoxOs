import AppKit
import Combine
import os

/// Notes written in the notch, kept on this Mac only: one rich-text file per note in
/// `Application Support/com.achyuthkp.VoxOS/Notes`, named by the note's id. RTF, or RTFD (one
/// flat file) once a note holds an image. Nothing syncs.
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

    /// Where a dictation started from a note goes: the note, and where its caret was. Stamped,
    /// it goes on a line of its own at the end, after the time (today's note, from any app).
    struct DictationTarget: Equatable {
        let note: UUID
        let location: Int
        let started: Date
        var stamped = false
    }

    /// Posted with a note's id when it changed on disk while it may be open: an open editor
    /// reads it again rather than saving over it.
    static let changedOutside = Notification.Name("NotchNotesChangedOutside")
    /// Posted with a note's id just before it is changed from outside its editor: an open editor
    /// saves what was typed, so the change starts from it.
    static let willChangeOutside = Notification.Name("NotchNotesWillChangeOutside")

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
    /// Counts changes to the notes tied to apps (a link, or a linked note's first line), so the
    /// band can follow them.
    @Published private(set) var appNotesChanged = 0
    /// First lines of the notes tied to apps, read as needed.
    private var appNoteLines: [UUID: String] = [:]

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
            let text = Self.read(Self.fileURL(of: id, in: self.folder))?.string
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
            guard ["rtf", "rtfd"].contains(url.pathExtension),
                let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
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

    // MARK: Today's note

    /// The note for today, made the first time it is asked for, with the date as its heading;
    /// opened either way.
    @discardableResult
    func openToday(now: Date = Date(), calendar: Calendar = .current) -> UUID {
        let id = todayNote(now: now, calendar: calendar)
        searching = false
        query = ""
        openID = id
        return id
    }

    /// Today's note, made if there is none yet; not opened.
    func todayNote(now: Date = Date(), calendar: Calendar = .current) -> UUID {
        loadIfNeeded()
        let day = Self.dayKey(now, calendar: calendar)
        if let saved = defaults.dictionary(forKey: DefaultsKeys.notchDailyNote) as? [String: String],
            saved["day"] == day, let id = saved["id"].flatMap(UUID.init(uuidString:)),
            notes.contains(where: { $0.id == id })
        {
            return id
        }
        let id = add(Self.heading(now.formatted(.dateTime.weekday(.wide).day().month(.wide))))
        defaults.set(["day": day, "id": id.uuidString], forKey: DefaultsKeys.notchDailyNote)
        return id
    }

    /// A new note holding `text`, at the top of the list, not opened.
    private func add(_ text: NSAttributedString) -> UUID {
        let note = Note(id: UUID(), title: Self.untitled, modified: Date())
        notes.insert(note, at: 0)
        save(text, for: note.id)
        return note.id
    }

    // MARK: Notes for an app

    private var appNotes: [String: String] {
        get { defaults.dictionary(forKey: DefaultsKeys.notchAppNotes) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: DefaultsKeys.notchAppNotes) }
    }

    /// The app a note shows with, by bundle id.
    func app(of note: UUID) -> String? {
        appNotes.first { $0.value == note.uuidString }?.key
    }

    /// Shows the note in the notch whenever the app is in front; nil unties it. An app has one
    /// note, and a note one app.
    func show(_ note: UUID, with bundleID: String?) {
        var links = appNotes.filter { $0.value != note.uuidString }
        if let bundleID { links[bundleID] = note.uuidString }
        appNotes = links
        appNoteLines[note] = nil
        appNotesChanged += 1
    }

    /// The note the collapsed notch shows: the one for the app in front, else the pinned one.
    func bandNoteID(frontApp: String?) -> UUID? {
        if let frontApp, let id = appNotes[frontApp].flatMap(UUID.init(uuidString:)), exists(id) {
            return id
        }
        return pinnedID
    }

    /// The band's line: the first line of `bandNoteID`'s note.
    func bandLine(frontApp: String?) -> String? {
        guard let id = bandNoteID(frontApp: frontApp) else { return nil }
        if id == pinnedID { return pinnedLine }
        if let line = appNoteLines[id] { return line }
        let line = Self.title(from: text(of: id).string)
        appNoteLines[id] = line
        return line
    }

    // MARK: Focus on an item

    /// Ticks the checklist item reading `item` in the note (the first one not yet ticked).
    func tick(_ item: String, in note: UUID) {
        NotificationCenter.default.post(name: Self.willChangeOutside, object: note)
        let text = NSMutableAttributedString(attributedString: self.text(of: note))
        let string = text.string as NSString
        var found: NSRange?
        string.enumerateSubstrings(
            in: NSRange(location: 0, length: string.length), options: [.byParagraphs, .substringNotRequired]
        ) { _, range, _, stop in
            let line = string.substring(with: range)
            if line.hasPrefix(NotchNoteFormat.unchecked + " "),
                NotchNoteFormat.strippingMarker(line).trimmingCharacters(in: .whitespaces) == item
            {
                found = NSRange(location: range.location, length: (NotchNoteFormat.unchecked as NSString).length)
                stop.pointee = true
            }
        }
        guard let found else { return }
        text.replaceCharacters(in: found, with: NotchNoteFormat.checked)
        save(text, for: note)
        NotificationCenter.default.post(name: Self.changedOutside, object: note)
    }

    nonisolated static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// A title line in H1, and an empty line under it to write on.
    nonisolated static func heading(_ title: String) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: title + "\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: NotchNoteFormat.headingSizes[0], weight: .bold),
                .foregroundColor: NotchNoteFormat.textColor,
            ])
        result.append(NSAttributedString(string: "", attributes: NotchNoteFormat.bodyAttributes))
        return result
    }

    // MARK: Meetings

    static var savesMeetings: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.meetingNotesToNotes) }

    /// A note kept for one occurrence of a calendar event, written in during the call; the
    /// meeting's write-up goes into it afterwards.
    struct MeetingLink: Codable, Equatable {
        let note: UUID
        let title: String
        let start: Date
    }

    /// Links older than this are dropped when a new one is made.
    nonisolated static let meetingLinkLifetime: TimeInterval = 14 * 24 * 3600

    private var meetingLinks: [String: MeetingLink] {
        get {
            defaults.data(forKey: DefaultsKeys.notchMeetingNotes)
                .flatMap { try? JSONDecoder().decode([String: MeetingLink].self, from: $0) } ?? [:]
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: DefaultsKeys.notchMeetingNotes)
        }
    }

    /// Opens the note for this meeting, made the first time with its title and time.
    @discardableResult
    func openMeetingNote(
        key: String, title: String, start: Date, attendees: [String] = [], agenda: String? = nil, link: URL? = nil,
        now: Date = Date()
    ) -> UUID {
        loadIfNeeded()
        if let link = meetingLinks[key], notes.contains(where: { $0.id == link.note }) {
            searching = false
            query = ""
            openID = link.note
            return link.note
        }
        let id = create(text: "")
        let text = NSMutableAttributedString(attributedString: Self.meetingHeader(title: title, date: start))
        text.append(Self.meetingDetails(attendees: attendees, agenda: agenda, link: link))
        save(text, for: id)
        var links = meetingLinks.filter { now.timeIntervalSince($0.value.start) < Self.meetingLinkLifetime }
        links[key] = MeetingLink(note: id, title: title, start: start)
        meetingLinks = links
        return id
    }

    /// The note made for this meeting during the call: same title, started within the half day
    /// before the write-up.
    nonisolated static func linkedNote(
        in links: [MeetingLink], title: String, date: Date, existing: Set<UUID>
    ) -> UUID? {
        links.filter {
            $0.title == title && existing.contains($0.note) && abs(date.timeIntervalSince($0.start)) < 12 * 3600
        }
        .max { $0.start < $1.start }?.note
    }

    /// A meeting's notes: into the note written during the call when there is one, under what was
    /// written there; otherwise a note of their own with the title, when it was, the summary
    /// with its action items as a checklist, and the transcript under them.
    @discardableResult
    func saveMeeting(title: String, date: Date, notes summary: String?, transcript: String) -> UUID {
        loadIfNeeded()
        let body = Self.meetingBody(notes: summary, transcript: transcript)
        if let linked = Self.linkedNote(
            in: Array(meetingLinks.values), title: title, date: date, existing: Set(notes.map(\.id)))
        {
            let text = NSMutableAttributedString(attributedString: self.text(of: linked))
            if !text.string.hasSuffix("\n") {
                text.append(NSAttributedString(string: "\n", attributes: NotchNoteFormat.bodyAttributes))
            }
            text.append(NSAttributedString(string: "\n", attributes: NotchNoteFormat.bodyAttributes))
            text.append(body)
            save(text, for: linked)
            return linked
        }
        let id = create(text: "")
        openID = nil
        save(Self.meetingNote(title: title, date: date, notes: summary, transcript: transcript), for: id)
        return id
    }

    nonisolated static func meetingNote(title: String, date: Date, notes summary: String?, transcript: String)
        -> NSAttributedString
    {
        let result = NSMutableAttributedString(attributedString: meetingHeader(title: title, date: date))
        result.append(meetingBody(notes: summary, transcript: transcript))
        return result
    }

    /// The lines under a write-up's "Action items" heading, without their bullets.
    nonisolated static func actionItems(from summary: String) -> [String] {
        var inActions = false
        var items: [String] = []
        for line in NotchNoteFormat.fromMarkdown(summary).components(separatedBy: .newlines) {
            let label = line.trimmingCharacters(in: CharacterSet(charactersIn: ": ")).lowercased()
            if ["summary", "decisions", "action items"].contains(label) {
                inActions = label == "action items"
                continue
            }
            let item = NotchNoteFormat.strippingMarker(line).trimmingCharacters(in: .whitespaces)
            if inActions, !item.isEmpty, NotchNoteFormat.kind(of: line) != nil { items.append(item) }
        }
        return items
    }

    /// From the calendar: who is coming, the event's notes as the agenda, and the call's link;
    /// then an empty line to write on.
    nonisolated static func meetingDetails(attendees: [String], agenda: String?, link: URL?) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let body = NotchNoteFormat.bodyAttributes
        let heading: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NotchNoteFormat.headingSizes[2], weight: .bold),
            .foregroundColor: NotchNoteFormat.textColor,
        ]
        if !attendees.isEmpty {
            result.append(NSAttributedString(string: String(localized: "Attendees") + "\n", attributes: heading))
            result.append(NSAttributedString(string: attendees.joined(separator: ", ") + "\n\n", attributes: body))
        }
        if let agenda, !agenda.isEmpty {
            result.append(NSAttributedString(string: String(localized: "Agenda") + "\n", attributes: heading))
            result.append(NSAttributedString(string: agenda + "\n\n", attributes: body))
        }
        if let link {
            var linked = body
            linked[.link] = link
            result.append(NSAttributedString(string: link.absoluteString, attributes: linked))
            result.append(NSAttributedString(string: "\n\n", attributes: body))
        }
        result.append(NSAttributedString(string: String(localized: "Notes") + "\n", attributes: heading))
        result.append(NSAttributedString(string: "", attributes: body))
        return result
    }

    /// The title in H1, when it was, and an empty line.
    nonisolated static func meetingHeader(title: String, date: Date) -> NSAttributedString {
        let result = NSMutableAttributedString()
        func add(_ text: String, font: NSFont, color: NSColor = NotchNoteFormat.textColor) {
            result.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: color]))
        }
        add(title, font: .systemFont(ofSize: NotchNoteFormat.headingSizes[0], weight: .bold))
        add(
            date.formatted(date: .abbreviated, time: .shortened), font: NotchNoteFormat.bodyFont,
            color: NotchNoteFormat.textColor.withAlphaComponent(0.6))
        add("", font: NotchNoteFormat.bodyFont)
        return result
    }

    /// The summary with its action items as a checklist, and the transcript under it.
    nonisolated static func meetingBody(notes summary: String?, transcript: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        func add(_ text: String, font: NSFont, color: NSColor = NotchNoteFormat.textColor) {
            result.append(NSAttributedString(string: text + "\n", attributes: [.font: font, .foregroundColor: color]))
        }
        let heading = NSFont.systemFont(ofSize: NotchNoteFormat.headingSizes[2], weight: .bold)
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
    func beginDictation(into note: UUID, at location: Int, stamped: Bool = false, now: Date = Date()) {
        dictation = DictationTarget(note: note, location: location, started: now, stamped: stamped)
    }

    /// The recorder starts, and what is said goes on its own line at the end of today's note,
    /// after the time; the app in front gets nothing.
    func dictateIntoToday(now: Date = Date()) {
        beginDictation(into: todayNote(now: now), at: Int.max, stamped: true, now: now)
        NotificationCenter.default.post(name: .toggleRecorderPanel, object: nil)
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
        NotificationCenter.default.post(name: Self.willChangeOutside, object: target.note)
        let text = NSMutableAttributedString(attributedString: self.text(of: target.note))
        let location = min(max(0, target.location), text.length)
        let before = (text.string as NSString).substring(to: location)
        let piece =
            target.stamped
            ? Self.stamped(dictated, after: before, at: Date())
            : Self.joining(dictated, after: before)
        text.insert(NSAttributedString(string: piece, attributes: NotchNoteFormat.bodyAttributes), at: location)
        save(text, for: target.note)
        NotificationCenter.default.post(name: Self.changedOutside, object: target.note)
        // Into today's note from another app: it stays there, out of the way.
        guard !target.stamped else { return }
        openID = target.note
        // After the recorder has gone: while it shows, the card stays hidden and would not pin.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Self.showInNotch() }
    }

    /// "10:42 what was said", on a line of its own.
    nonisolated static func stamped(_ dictated: String, after before: String, at date: Date) -> String {
        let line =
            date.formatted(date: .omitted, time: .shortened) + " "
            + dictated.trimmingCharacters(in: .whitespacesAndNewlines)
        return before.isEmpty || before.hasSuffix("\n") ? line : "\n" + line
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
        Self.read(Self.fileURL(of: id, in: folder)) ?? NSAttributedString(string: "")
    }

    func save(_ text: NSAttributedString, for id: UUID) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Images need RTFD; a note without one stays plain RTF, as notes always were.
            let rich = text.containsAttachments
            let data = try text.data(
                from: NSRange(location: 0, length: text.length),
                documentAttributes: [.documentType: rich ? NSAttributedString.DocumentType.rtfd : .rtf])
            try data.write(to: rich ? richURL(of: id) : url(of: id), options: .atomic)
            try? FileManager.default.removeItem(at: rich ? url(of: id) : richURL(of: id))
        } catch {
            logger.error("Note not saved: \(error, privacy: .public)")
            return
        }
        let title = Self.title(from: text.string)
        if id == pinnedID { pinnedLine = title }
        if appNoteLines[id] != nil, appNoteLines[id] != title {
            appNoteLines[id] = title
            appNotesChanged += 1
        }
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
        if app(of: id) != nil { show(id, with: nil) }
        try? FileManager.default.removeItem(at: url(of: id))
        try? FileManager.default.removeItem(at: richURL(of: id))
        notes.removeAll { $0.id == id }
        if openID == id { openID = nil }
    }

    /// The note's text on the clipboard: rich for apps that take it, plain for the rest.
    func copy(_ id: UUID) {
        let text = text(of: id)
        let board = NSPasteboard.general
        board.clearContents()
        let range = NSRange(location: 0, length: text.length)
        if text.containsAttachments,
            let rtfd = try? text.data(
                from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
        {
            board.setData(rtfd, forType: .rtfd)
        }
        if let rtf = try? text.data(
            from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        {
            board.setData(rtf, forType: .rtf)
        }
        board.setString(text.string, forType: .string)
    }

    private func url(of id: UUID) -> URL {
        folder.appendingPathComponent(id.uuidString).appendingPathExtension("rtf")
    }

    private func richURL(of id: UUID) -> URL {
        folder.appendingPathComponent(id.uuidString).appendingPathExtension("rtfd")
    }

    private func exists(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(of: id).path)
            || FileManager.default.fileExists(atPath: richURL(of: id).path)
    }

    /// The note's file: RTFD when it has one, else RTF.
    private static func fileURL(of id: UUID, in folder: URL) -> URL {
        let rich = folder.appendingPathComponent(id.uuidString).appendingPathExtension("rtfd")
        return FileManager.default.fileExists(atPath: rich.path)
            ? rich : folder.appendingPathComponent(id.uuidString).appendingPathExtension("rtf")
    }

    private static func read(_ url: URL) -> NSAttributedString? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let type: NSAttributedString.DocumentType = url.pathExtension == "rtfd" ? .rtfd : .rtf
        return try? NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil)
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
