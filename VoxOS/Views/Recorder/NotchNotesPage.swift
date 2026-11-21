import AppKit
import SwiftUI

/// Notes in the notch: the list, newest first, or one note open with its toolbar. Opening a note
/// lets the card take the keyboard (see `NotchHomePanel.acceptsKeyboard`); typing never makes
/// VoxOS the active app, and the card stays open while it has the keyboard.
struct NotchNotesPage: View {
    @ObservedObject var notes: NotchNotes
    @FocusState private var searchFocused: Bool

    static var cardHeight: CGFloat { 300 }

    var body: some View {
        Group {
            if let note = notes.openNote {
                NotchNoteEditorView(note: note, notes: notes)
                    .id(note.id)
            } else {
                list
            }
        }
        .padding(.top, NotchHome.Card.top)
        .padding(.horizontal, AgentComposer.panelInset + 4)
        .padding(.bottom, NotchHome.Card.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { notes.loadIfNeeded() }
        // Leaving the page puts the search away, and gives the keyboard back.
        .onDisappear { stopSearch() }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if notes.searching {
                    searchField
                    NotchNoteCircleButton(symbol: "xmark", label: "Close Search") { stopSearch() }
                } else {
                    Text("Notes")
                        .font(.app(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    if !notes.notes.isEmpty {
                        NotchNoteCircleButton(symbol: "magnifyingglass", label: "Search Notes") {
                            notes.searching = true
                        }
                    }
                    NotchNoteCircleButton(symbol: "calendar", label: "Today's Note") { notes.openToday() }
                    NotchNoteCircleButton(symbol: "square.and.pencil", label: "New Note") { notes.create() }
                }
            }
            .frame(height: NotchNoteCircleButton.size)
            if notes.notes.isEmpty {
                NotchPageHint(symbol: "note.text", text: "Notes you write here stay on this Mac")
            } else if notes.shown.isEmpty {
                NotchPageHint(symbol: "magnifyingglass", text: "No notes match")
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 4) {
                        ForEach(notes.shown) { note in
                            NotchNoteRow(note: note, pinned: notes.pinnedID == note.id) { notes.openID = note.id }
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.5))
            TextField("Search Notes", text: $notes.query)
                .textFieldStyle(.plain)
                .font(.app(size: 13))
                .foregroundStyle(.white)
                .focused($searchFocused)
                .onExitCommand { stopSearch() }
        }
        .padding(.horizontal, 12)
        .frame(height: NotchNoteCircleButton.size)
        .background(Capsule().fill(.white.opacity(0.1)))
        // The card takes the keyboard once the field shows; the field takes it a moment after.
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { searchFocused = true }
        }
    }

    private func stopSearch() {
        guard notes.searching || !notes.query.isEmpty else { return }
        notes.searching = false
        notes.query = ""
    }
}

private struct NotchNoteRow: View {
    let note: NotchNotes.Note
    let pinned: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if pinned {
                    Image(systemName: "pin.fill").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color(red: 1, green: 0.84, blue: 0.3))
                        .help(Text("Pinned to the notch"))
                }
                Text(verbatim: note.title)
                    .font(.app(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(verbatim: NotchNotes.edited(note.modified))
                    .font(.app(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(Capsule().fill(.white.opacity(hovered ? 0.16 : 0.09)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// One note: back, when it was edited, copy and delete; the text; and the formatting toolbar.
private struct NotchNoteEditorView: View {
    let note: NotchNotes.Note
    @ObservedObject var notes: NotchNotes
    @StateObject private var controller = NotchNoteEditorController()
    /// Delete takes a second click, so a slip never loses a note.
    @State private var confirmingDelete = false
    /// How many reminders the last click added, shown for a moment.
    @State private var remindersAdded: Int?
    /// An AI action under way, and why the last one failed.
    @State private var aiRunning: NotchNoteAI.Action?
    @State private var aiError: String?
    /// Apple Notes took this note.
    @State private var sentToNotes = false

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                NotchNoteCircleButton(symbol: "chevron.left", label: "All Notes") { close() }
                Group {
                    if let aiError {
                        Text(verbatim: aiError).foregroundStyle(.orange)
                    } else {
                        Text(verbatim: NotchNotes.edited(note.modified)).foregroundStyle(.white.opacity(0.55))
                    }
                }
                .font(.app(size: 12, weight: .semibold))
                .lineLimit(1)
                Spacer(minLength: 4)
                NotchNoteCircleButton(symbol: "mic.fill", label: "Dictate into This Note") { dictate() }
                aiMenu
                moreMenu
                NotchNoteCircleButton(symbol: "doc.on.doc.fill", label: "Copy Note") {
                    controller.save()
                    notes.copy(note.id)
                }
                NotchNoteCircleButton(
                    symbol: "trash.fill", label: confirmingDelete ? "Click Again to Delete" : "Delete Note",
                    tint: confirmingDelete ? .red : nil
                ) {
                    if confirmingDelete { notes.delete(note.id) } else { confirmingDelete = true }
                }
            }
            .frame(height: NotchNoteCircleButton.size)
            ZStack(alignment: .topLeading) {
                NotchNoteTextEditor(note: note.id, notes: notes, controller: controller)
                if controller.isEmpty {
                    Text("Start writing…")
                        .font(.system(size: NotchNoteFormat.bodySize))
                        .foregroundStyle(.white.opacity(0.35))
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            toolbar
        }
        .onChange(of: controller.isEmpty) { _, _ in confirmingDelete = false }
        .onDisappear { controller.save() }
    }

    private func close() {
        controller.save()
        notes.openID = nil
    }

    /// A copy in Apple Notes; macOS asks once whether VoxOS may control Notes.
    private func sendToAppleNotes() {
        controller.save()
        let text = notes.text(of: note.id)
        Task { @MainActor in
            if await NotchNoteExport.sendToAppleNotes(text) {
                sentToNotes = true
            } else {
                aiError = String(localized: "Apple Notes did not take the note. Check Automation in Privacy settings.")
            }
        }
    }

    /// The recorder starts as with the recording shortcut, and what is said goes into this note
    /// where the caret is, rather than into the app in front.
    private func dictate() {
        controller.save()
        notes.beginDictation(into: note.id, at: controller.caret)
        NotificationCenter.default.post(name: .toggleRecorderPanel, object: nil)
    }

    /// Sparkles: the AI actions on this note; a spinner while one runs.
    private var aiMenu: some View {
        Menu {
            ForEach(NotchNoteAI.Action.allCases) { action in
                Button {
                    runAI(action)
                } label: {
                    Label(action.title, systemImage: action.symbol)
                }
            }
        } label: {
            NotchNoteMenuLabel(symbol: "sparkles", busy: aiRunning != nil)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(aiRunning != nil || controller.isEmpty)
        .help(Text("AI"))
        .accessibilityLabel(Text("AI"))
    }

    /// Pinning, and what can be done with the checklist.
    private var moreMenu: some View {
        Menu {
            Button {
                notes.togglePin(note.id)
            } label: {
                if notes.pinnedID == note.id {
                    Label("Unpin from the Notch", systemImage: "pin.slash")
                } else {
                    Label("Pin to the Notch", systemImage: "pin")
                }
            }
            Divider()
            Button {
                addToReminders()
            } label: {
                Label(
                    remindersAdded.map { "Added \($0) to Reminders" } ?? "Add Checklist to Reminders",
                    systemImage: "checklist")
            }
            .disabled(controller.uncheckedItems == 0 || remindersAdded != nil)
            Button {
                controller.perform(.clearTicked)
            } label: {
                Label("Clear Ticked Items", systemImage: "checkmark.circle.badge.xmark")
            }
            .disabled(!controller.hasTicked)
            Divider()
            Button {
                controller.save()
                NotchNoteExport.saveMarkdown(notes.text(of: note.id), title: note.title)
            } label: {
                Label("Export as Markdown…", systemImage: "doc.plaintext")
            }
            Button {
                controller.save()
                NotchNoteExport.savePDF(notes.text(of: note.id), title: note.title)
            } label: {
                Label("Export as PDF…", systemImage: "doc.richtext")
            }
            Button {
                sendToAppleNotes()
            } label: {
                Label(sentToNotes ? "Added to Apple Notes" : "Add to Apple Notes", systemImage: "note.text.badge.plus")
            }
            .disabled(sentToNotes)
        } label: {
            NotchNoteMenuLabel(symbol: notes.pinnedID == note.id ? "pin.fill" : "ellipsis", busy: false)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("More"))
        .accessibilityLabel(Text("More"))
    }

    private func runAI(_ action: NotchNoteAI.Action) {
        controller.save()
        let text = controller.textView?.string ?? ""
        aiError = nil
        aiRunning = action
        Task { @MainActor in
            defer { aiRunning = nil }
            do {
                let result = try await NotchNoteAI.run(action, on: text)
                controller.apply(result, placement: action.placement)
            } catch {
                aiError = error.localizedDescription
                try? await Task.sleep(for: .seconds(4))
                aiError = nil
            }
        }
    }

    /// The checklist's unticked items as reminders in the default list; a date or time in an
    /// item becomes its due date.
    private func addToReminders() {
        guard remindersAdded == nil else { return }
        let items = NotchNoteFormat.uncheckedItems(in: controller.textView?.string ?? "")
            .map { NotchNoteFormat.reminderItem(from: $0) }
        Task { @MainActor in
            let added = await NotchReminders.shared.add(items)
            remindersAdded = added
            try? await Task.sleep(for: .seconds(2))
            remindersAdded = nil
        }
    }

    private var toolbar: some View {
        HStack(spacing: 5) {
            tool("bold", "Bold", .bold)
            tool("italic", "Italic", .italic)
            tool("underline", "Underline", .underline)
            tool("highlighter", "Highlight", .highlight, tint: .yellow)
            divider
            text("H1", "Heading 1", .heading(1))
            text("H2", "Heading 2", .heading(2))
            text("H3", "Heading 3", .heading(3))
            divider
            tool("list.bullet", "Bulleted List", .list(.bullet))
            tool("list.number", "Numbered List", .list(.numbered))
            tool("checklist", "Checklist", .list(.checklist))
            tool("tablecells", "Table", .table)
        }
        .frame(height: NotchNoteCircleButton.size)
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 18).padding(.horizontal, 2)
    }

    private func tool(
        _ symbol: String, _ label: LocalizedStringKey, _ action: NotchNoteEditorController.Action, tint: Color? = nil
    ) -> some View {
        NotchNoteToolButton(
            label: label, action: { controller.perform(action) },
            content: {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(tint ?? .white.opacity(0.9))
            })
    }

    private func text(_ title: String, _ label: LocalizedStringKey, _ action: NotchNoteEditorController.Action)
        -> some View
    {
        NotchNoteToolButton(
            label: label, action: { controller.perform(action) },
            content: {
                Text(verbatim: title)
                    .font(.app(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
            })
    }
}

/// A round button in the note's top row.
private struct NotchNoteCircleButton: View {
    let symbol: String
    let label: LocalizedStringKey
    var tint: Color? = nil
    let action: () -> Void
    @State private var hovered = false

    static let size: CGFloat = 30

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint ?? .white.opacity(0.9))
                .frame(width: Self.size, height: Self.size)
                .background(Circle().fill((tint ?? .white).opacity(hovered ? 0.26 : 0.14)))
                .overlay(Circle().strokeBorder(.white.opacity(0.1), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }
}

/// A menu's button in the note's top row, drawn like the round buttons beside it.
private struct NotchNoteMenuLabel: View {
    let symbol: String
    let busy: Bool

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.14))
            Circle().strokeBorder(.white.opacity(0.1), lineWidth: 1)
            if busy {
                ProgressView().controlSize(.mini).tint(.white)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: NotchNoteCircleButton.size, height: NotchNoteCircleButton.size)
    }
}

/// A round glass button in the toolbar.
private struct NotchNoteToolButton<Label: View>: View {
    let label: LocalizedStringKey
    let action: () -> Void
    @ViewBuilder let content: () -> Label
    @State private var hovered = false

    var body: some View {
        let size = NotchNoteCircleButton.size
        Button(action: action) {
            content()
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(hovered ? 0.24 : 0.12)))
                .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }
}

// MARK: - Editor

/// Connects the toolbar to the text view, and saves.
@MainActor
final class NotchNoteEditorController: ObservableObject {
    enum Action: Equatable {
        case bold, italic, underline, highlight
        case heading(Int)
        case list(NotchNoteFormat.List)
        case table
        case clearTicked
    }

    @Published private(set) var isEmpty = true
    /// The checklist's items not yet ticked.
    @Published private(set) var uncheckedItems = 0
    /// Some checklist items are ticked.
    @Published private(set) var hasTicked = false
    weak var textView: NotchNoteTextView?
    var saveNow: () -> Void = {}

    /// Where the caret is, for a dictation to go.
    var caret: Int { textView?.selectedRange().location ?? (textView?.string as NSString?)?.length ?? 0 }

    func save() { saveNow() }

    func textChanged() {
        let text = textView?.string ?? ""
        isEmpty = text.isEmpty
        let unchecked = NotchNoteFormat.uncheckedItems(in: text).count
        if unchecked != uncheckedItems { uncheckedItems = unchecked }
        let ticked = NotchNoteFormat.hasTicked(text)
        if ticked != hasTicked { hasTicked = ticked }
    }

    func perform(_ action: Action) {
        guard let textView, let storage = textView.textStorage else { return }
        textView.window?.makeFirstResponder(textView)
        let selection = textView.selectedRange()
        let string = textView.string as NSString
        switch action {
        case .bold, .italic:
            let trait: NotchNoteFormat.Trait = action == .bold ? .bold : .italic
            if selection.length == 0 {
                textView.typingAttributes = NotchNoteFormat.toggled(trait, typing: textView.typingAttributes)
            } else {
                transform(selection, in: textView) { NotchNoteFormat.toggle(trait, in: $0, range: $1) }
            }
        case .underline:
            if selection.length == 0 {
                flipTyping(.underlineStyle, value: NSUnderlineStyle.single.rawValue, in: textView)
            } else {
                transform(selection, in: textView) { NotchNoteFormat.toggleUnderline(in: $0, range: $1) }
            }
        case .highlight:
            if selection.length == 0 {
                flipTyping(.backgroundColor, value: NotchNoteFormat.highlightColor, in: textView)
            } else {
                transform(selection, in: textView) { NotchNoteFormat.toggleHighlight(in: $0, range: $1) }
            }
        case .heading(let level):
            let paragraphs = string.paragraphRange(for: selection)
            if paragraphs.length == 0 {
                // An empty last line: the heading is what is typed next.
                var typing = textView.typingAttributes
                let font = typing[.font] as? NSFont
                let size = NotchNoteFormat.headingSizes[level - 1]
                typing[.font] =
                    font.flatMap(NotchNoteFormat.headingLevel(of:)) == level
                    ? NotchNoteFormat.bodyFont : NSFont.systemFont(ofSize: size, weight: .bold)
                textView.typingAttributes = typing
            } else {
                transform(paragraphs, in: textView, keep: selection) {
                    NotchNoteFormat.toggleHeading(level, in: $0, range: $1)
                }
                if let font = storage.attribute(.font, at: paragraphs.location, effectiveRange: nil) {
                    textView.typingAttributes[.font] = font
                }
            }
        case .list(let list):
            let paragraphs = string.paragraphRange(for: selection)
            let before = storage.length
            transform(paragraphs, in: textView, keep: nil) { NotchNoteFormat.toggleList(list, in: $0, range: $1) }
            let delta = storage.length - before
            let caret = selection.length == 0
            textView.setSelectedRange(
                caret
                    ? NSRange(location: max(paragraphs.location, selection.location + delta), length: 0)
                    : NSRange(location: paragraphs.location, length: max(0, paragraphs.length + delta)))
        case .table:
            var table = NotchNoteFormat.table()
            // A table starts on a line of its own.
            let atLineStart = selection.location == 0 || string.character(at: selection.location - 1) == 10
            if !atLineStart {
                let withBreak = NSMutableAttributedString(string: "\n", attributes: NotchNoteFormat.bodyAttributes)
                withBreak.append(table)
                table = withBreak
            }
            textView.insertText(table, replacementRange: selection)
            textView.typingAttributes = NotchNoteFormat.bodyAttributes
        case .clearTicked:
            let whole = NSRange(location: 0, length: storage.length)
            transform(whole, in: textView, keep: NSRange(location: 0, length: 0)) { text, _ in
                NotchNoteFormat.removeTicked(in: text)
            }
        }
        textChanged()
    }

    /// An AI result into the note: in its place, on top or under it, through the text view so it
    /// can be undone.
    func apply(_ result: String, placement: NotchNoteAI.Placement) {
        guard let textView, let storage = textView.textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        let body = NotchNoteFormat.bodyAttributes
        transform(whole, in: textView, keep: NSRange(location: 0, length: 0)) { text, range in
            switch placement {
            case .replace:
                text.replaceCharacters(in: range, with: NSAttributedString(string: result, attributes: body))
            case .top:
                text.insert(NSAttributedString(string: result + "\n\n", attributes: body), at: 0)
            case .bottom:
                let gap = text.length == 0 ? "" : "\n\n"
                text.append(NSAttributedString(string: gap + result, attributes: body))
            }
        }
        textChanged()
        saveNow()
    }

    /// Replaces `range` with a formatted copy of itself, through the text view so it can be undone.
    private func transform(
        _ range: NSRange, in textView: NSTextView, keep selection: NSRange? = nil,
        _ change: (NSMutableAttributedString, NSRange) -> Void
    ) {
        guard let storage = textView.textStorage else { return }
        let copy = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: range))
        change(copy, NSRange(location: 0, length: copy.length))
        guard textView.shouldChangeText(in: range, replacementString: copy.string) else { return }
        storage.replaceCharacters(in: range, with: copy)
        textView.didChangeText()
        textView.setSelectedRange(selection ?? range)
    }

    private func flipTyping(_ key: NSAttributedString.Key, value: Any, in textView: NSTextView) {
        if textView.typingAttributes[key] == nil {
            textView.typingAttributes[key] = value
        } else {
            textView.typingAttributes.removeValue(forKey: key)
        }
    }
}

/// The note's text view: ticks a box when its box is clicked, and handles the editing keys itself,
/// since the card's app is not the active one and its menus do not see them.
final class NotchNoteTextView: NSTextView {
    var onFormat: ((NotchNoteEditorController.Action) -> Void)?
    var onEscape: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let text = string as NSString
        for candidate in [index, index - 1] where candidate >= 0 && candidate < text.length {
            let atLineStart = candidate == 0 || text.character(at: candidate - 1) == 10
            let character = text.substring(with: NSRange(location: candidate, length: 1))
            guard atLineStart, let ticked = NotchNoteFormat.toggledBox(character) else { continue }
            let range = NSRange(location: candidate, length: 1)
            if shouldChangeText(in: range, replacementString: ticked) {
                textStorage?.replaceCharacters(in: range, with: ticked)
                didChangeText()
            }
            return
        }
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard window?.firstResponder === self, flags.contains(.command),
            let key = event.charactersIgnoringModifiers?.lowercased()
        else { return super.performKeyEquivalent(with: event) }
        switch key {
        case "b": onFormat?(.bold)
        case "i": onFormat?(.italic)
        case "u": onFormat?(.underline)
        case "z": flags.contains(.shift) ? undoManager?.redo() : undoManager?.undo()
        case "a": selectAll(nil)
        case "c": copy(nil)
        case "x": cut(nil)
        // Plain, so pasted text takes the note's own white instead of the source's colours.
        case "v": pasteAsPlainText(nil)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

private struct NotchNoteTextEditor: NSViewRepresentable {
    let note: UUID
    let notes: NotchNotes
    let controller: NotchNoteEditorController

    func makeCoordinator() -> Coordinator { Coordinator(note: note, notes: notes, controller: controller) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        // TextKit 1: tables (NSTextTable) are drawn only by it.
        let textView = NotchNoteTextView(usingTextLayoutManager: false)
        textView.drawsBackground = false
        textView.isRichText = true
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.usesFindBar = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.insertionPointColor = .white
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(notes.text(of: note))
        textView.typingAttributes = NotchNoteFormat.bodyAttributes
        textView.selectedTextAttributes = [.backgroundColor: NSColor.white.withAlphaComponent(0.25)]
        textView.delegate = context.coordinator
        textView.onFormat = { [weak controller] action in controller?.perform(action) }
        textView.onEscape = { [weak notes, weak controller] in
            controller?.save()
            notes?.openID = nil
        }
        scroll.documentView = textView
        controller.textView = textView
        controller.saveNow = { [weak coordinator = context.coordinator] in coordinator?.saveNow() }
        controller.textChanged()
        // Ready to type as soon as the note opens.
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {}

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.saveNow()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let note: UUID
        let notes: NotchNotes
        let controller: NotchNoteEditorController
        private var pending: Task<Void, Never>?
        private var dirty = false

        init(note: UUID, notes: NotchNotes, controller: NotchNoteEditorController) {
            self.note = note
            self.notes = notes
            self.controller = controller
        }

        func textDidChange(_ notification: Notification) {
            dirty = true
            controller.textChanged()
            pending?.cancel()
            pending = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                self?.saveNow()
            }
        }

        func saveNow() {
            pending?.cancel()
            guard dirty, let text = controller.textView?.textStorage else { return }
            dirty = false
            notes.save(NSAttributedString(attributedString: text), for: note)
        }

        /// Return carries a list on ("3. " after "2. "); on an empty item it ends the list.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let selection = textView.selectedRange()
            let string = textView.string as NSString
            var line = string.paragraphRange(for: NSRange(location: selection.location, length: 0))
            if line.length > 0, string.character(at: line.location + line.length - 1) == 10 { line.length -= 1 }
            guard let continuation = NotchNoteFormat.continuation(after: string.substring(with: line)) else {
                return false
            }
            switch continuation {
            case .marker(let marker):
                textView.insertText("\n" + marker, replacementRange: selection)
            case .end:
                let marker = NSRange(
                    location: line.location,
                    length: NotchNoteFormat.markerLength(of: string.substring(with: line)))
                if textView.shouldChangeText(in: marker, replacementString: "") {
                    textView.textStorage?.replaceCharacters(in: marker, with: "")
                    textView.didChangeText()
                }
            }
            return true
        }
    }
}
