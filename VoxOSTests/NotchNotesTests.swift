import AppKit
import Foundation
import Testing

@testable import VoxOS

/// Notes in the notch, the redesigned card's window, and the app list's order.
@Suite
@MainActor
struct NotchNotesTests {

    // MARK: Formatting

    private static func body(_ string: String) -> NSMutableAttributedString {
        NSMutableAttributedString(string: string, attributes: NotchNoteFormat.bodyAttributes)
    }

    private static func isBold(_ text: NSAttributedString, at index: Int) -> Bool {
        let font = text.attribute(.font, at: index, effectiveRange: nil) as? NSFont
        return font?.fontDescriptor.symbolicTraits.contains(.bold) == true
    }

    @Test func boldGoesOnThenOffTheSelection() {
        let text = Self.body("hello world")
        let range = NSRange(location: 0, length: 5)
        NotchNoteFormat.toggle(.bold, in: text, range: range)
        #expect(Self.isBold(text, at: 0))
        #expect(!Self.isBold(text, at: 6))
        NotchNoteFormat.toggle(.bold, in: text, range: range)
        #expect(!Self.isBold(text, at: 0))
    }

    @Test func aPartlyBoldSelectionBecomesAllBold() {
        let text = Self.body("hello world")
        NotchNoteFormat.toggle(.bold, in: text, range: NSRange(location: 0, length: 3))
        NotchNoteFormat.toggle(.bold, in: text, range: NSRange(location: 0, length: 11))
        #expect(Self.isBold(text, at: 0) && Self.isBold(text, at: 10))
    }

    @Test func underlineAndHighlightToggle() {
        let text = Self.body("note")
        let all = NSRange(location: 0, length: 4)
        NotchNoteFormat.toggleUnderline(in: text, range: all)
        NotchNoteFormat.toggleHighlight(in: text, range: all)
        #expect(text.attribute(.underlineStyle, at: 1, effectiveRange: nil) != nil)
        #expect(text.attribute(.backgroundColor, at: 1, effectiveRange: nil) != nil)
        NotchNoteFormat.toggleUnderline(in: text, range: all)
        NotchNoteFormat.toggleHighlight(in: text, range: all)
        #expect(text.attribute(.underlineStyle, at: 1, effectiveRange: nil) == nil)
        #expect(text.attribute(.backgroundColor, at: 1, effectiveRange: nil) == nil)
    }

    @Test func aHeadingTakesTheWholeLineAndComesOffAgain() {
        let text = Self.body("Title\nbody")
        NotchNoteFormat.toggleHeading(1, in: text, range: NSRange(location: 2, length: 0))
        let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font.flatMap(NotchNoteFormat.headingLevel(of:)) == 1)
        #expect((text.attribute(.font, at: 7, effectiveRange: nil) as? NSFont)?.pointSize == NotchNoteFormat.bodySize)
        NotchNoteFormat.toggleHeading(1, in: text, range: NSRange(location: 2, length: 0))
        #expect((text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == NotchNoteFormat.bodySize)
    }

    @Test func listsNumberTheLinesAndSwitchKinds() {
        let text = Self.body("milk\neggs\nbread")
        NotchNoteFormat.toggleList(.numbered, in: text, range: NSRange(location: 0, length: text.length))
        #expect(text.string == "1. milk\n2. eggs\n3. bread")
        NotchNoteFormat.toggleList(.checklist, in: text, range: NSRange(location: 0, length: text.length))
        #expect(text.string == "☐ milk\n☐ eggs\n☐ bread")
        NotchNoteFormat.toggleList(.checklist, in: text, range: NSRange(location: 0, length: text.length))
        #expect(text.string == "milk\neggs\nbread")
    }

    @Test func aListStartsOnAnEmptyNote() {
        let text = Self.body("")
        NotchNoteFormat.toggleList(.bullet, in: text, range: NSRange(location: 0, length: 0))
        #expect(text.string == "• ")
    }

    @Test func returnCarriesTheListOn() {
        #expect(NotchNoteFormat.continuation(after: "• milk") == .marker("• "))
        #expect(NotchNoteFormat.continuation(after: "9. ninth") == .marker("10. "))
        #expect(NotchNoteFormat.continuation(after: "☑ done") == .marker("☐ "))
        #expect(NotchNoteFormat.continuation(after: "• ") == .end)
        #expect(NotchNoteFormat.continuation(after: "plain") == nil)
        #expect(NotchNoteFormat.continuation(after: "2024 was a year") == nil)
    }

    @Test func boxesTick() {
        #expect(NotchNoteFormat.toggledBox("☐") == "☑")
        #expect(NotchNoteFormat.toggledBox("☑") == "☐")
        #expect(NotchNoteFormat.toggledBox("x") == nil)
    }

    @Test func aTableIsOneParagraphPerCell() {
        let table = NotchNoteFormat.table(rows: 2, columns: 3)
        #expect(table.string == String(repeating: "\n", count: 6))
        let style = table.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect((style?.textBlocks.first as? NSTextTableBlock)?.table.numberOfColumns == 3)
    }

    // MARK: Notes

    @Test func aNoteIsTitledByItsFirstLineWithWords() {
        #expect(NotchNotes.title(from: "\n  \n• Groceries\nmilk") == "Groceries")
        #expect(NotchNotes.title(from: "") == NotchNotes.untitled)
        #expect(NotchNotes.title(from: String(repeating: "a", count: 80)).count == 60)
    }

    @Test func editedSaysTheTimeTodayAndYesterdayByName() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let yesterday = now.addingTimeInterval(-86_400)
        #expect(NotchNotes.edited(now, now: now, calendar: calendar).hasPrefix("Edited "))
        #expect(NotchNotes.edited(yesterday, now: now, calendar: calendar) == "Edited Yesterday")
    }

    @Test func notesAreSavedReadAndDeleted() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NotchNotesTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let notes = NotchNotes(folder: folder)
        let id = notes.create()
        #expect(notes.openID == id)
        notes.save(Self.body("Shopping\nmilk"), for: id)
        #expect(notes.notes.first?.title == "Shopping")
        let reread = NotchNotes(folder: folder)
        reread.loadIfNeeded()
        #expect(reread.notes.map(\.id) == [id])
        #expect(reread.text(of: id).string == "Shopping\nmilk")
        reread.delete(id)
        #expect(reread.notes.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func searchMatchesEveryWordInTitleOrText() {
        let notes = [
            NotchNotes.Note(id: UUID(), title: "Groceries", modified: Date(), text: "Groceries\nmilk, crème fraîche"),
            NotchNotes.Note(id: UUID(), title: "Trip", modified: Date(), text: "Trip\npack the charger"),
        ]
        #expect(NotchNotes.matching(notes, query: "").count == 2)
        #expect(NotchNotes.matching(notes, query: "creme").map(\.title) == ["Groceries"])
        #expect(NotchNotes.matching(notes, query: "TRIP charger").map(\.title) == ["Trip"])
        #expect(NotchNotes.matching(notes, query: "milk charger").isEmpty)
    }

    @Test func aDictationGoesIntoTheNoteOnceAndLapses() {
        let notes = NotchNotes(folder: FileManager.default.temporaryDirectory.appendingPathComponent("unused"))
        let id = UUID()
        let start = Date(timeIntervalSince1970: 1000)
        notes.beginDictation(into: id, at: 4, now: start)
        #expect(notes.takeDictation(now: start.addingTimeInterval(5))?.note == id)
        #expect(notes.takeDictation(now: start.addingTimeInterval(6)) == nil, "used once")
        notes.beginDictation(into: id, at: 4, now: start)
        #expect(notes.takeDictation(now: start.addingTimeInterval(NotchNotes.dictationLifetime + 1)) == nil)
    }

    @Test func dictatedTextIsSpacedFromTheWordBeforeIt() {
        #expect(NotchNotes.joining(" hello ", after: "word") == " hello")
        #expect(NotchNotes.joining("hello", after: "word ") == "hello")
        #expect(NotchNotes.joining("hello", after: "") == "hello")
        #expect(NotchNotes.joining("hello", after: "line\n") == "hello")
    }

    @Test func onlyUntickedItemsGoToReminders() {
        let text = "Shopping\n☐ milk\n☑ eggs\n☐  \n☐ bread"
        #expect(NotchNoteFormat.uncheckedItems(in: text) == ["milk", "bread"])
    }

    // MARK: The card

    @Test func theOpenWindowHasRoomForTheBarUnderTheCard() {
        let card = NotchHome.size(for: .expanded, notchWidth: 200, notchHeight: 32, cardHeight: 150)
        let window = NotchHome.windowSize(for: .expanded, notchWidth: 200, notchHeight: 32, cardHeight: 150)
        #expect(window.width == card.width)
        #expect(window.height == card.height + NotchHomeNavBar.space)
        // Closed, there is no bar.
        #expect(
            NotchHome.windowSize(for: .bare, notchWidth: 200, notchHeight: 32)
                == NotchHome.size(for: .bare, notchWidth: 200, notchHeight: 32))
    }

    @Test func pagesThatUseDragsKeepThem() {
        #expect(NotchHomeManager.keepsDrags(.shelf))
        #expect(NotchHomeManager.keepsDrags(.sound))
        #expect(NotchHomeManager.keepsDrags(.notes))
        #expect(!NotchHomeManager.keepsDrags(.music))
    }

    @Test func playingAppsComeFirstThenByName() {
        func app(_ name: String) -> NotchMixer.App {
            NotchMixer.App(bundleID: name, name: name, processes: [], gain: 1)
        }
        let ordered = NotchMixer.ordered([(app("Zoom"), true), (app("Arc"), false), (app("Music"), true)])
        #expect(ordered.map(\.name) == ["Music", "Zoom", "Arc"])
    }

    @Test func theTimerTakesItsSessionsColour() {
        #expect(NotchTimerPage.faceColor(for: .focus) != NotchTimerPage.faceColor(for: .shortBreak))
        #expect(NotchTimerPage.settingsHeight > NotchTimerPage.cardHeight)
    }
}
