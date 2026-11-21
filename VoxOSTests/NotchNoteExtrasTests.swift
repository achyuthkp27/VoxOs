import AppKit
import Foundation
import Testing

@testable import VoxOS

/// Notes taken out of the notch (Markdown, Apple Notes' HTML), today's note, a meeting's own
/// note, and a pomodoro that waits for calls and counts the day's focus.
@Suite
@MainActor
struct NotchNoteExtrasTests {
    private static func body(_ string: String) -> NSMutableAttributedString {
        NSMutableAttributedString(string: string, attributes: NotchNoteFormat.bodyAttributes)
    }

    private static func store() -> (NotchNotes, URL, UserDefaults) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NotchNoteExtras-\(UUID())")
        let defaults = UserDefaults(suiteName: "NotchNoteExtrasTests.\(UUID())")!
        return (NotchNotes(folder: folder, defaults: defaults), folder, defaults)
    }

    /// "Plan" in H1, a bold word, a bullet, a numbered item and two checklist items.
    private static var sample: NSAttributedString {
        let text = NSMutableAttributedString(attributedString: NotchNotes.heading("Plan"))
        text.append(body("Call the bank now\n• milk\n1. first\n☐ open\n☑ done"))
        let bank = (text.string as NSString).range(of: "bank")
        NotchNoteFormat.toggle(.bold, in: text, range: bank)
        return text
    }

    // MARK: Export

    @Test func markdownKeepsHeadingsEmphasisAndLists() {
        let markdown = NotchNoteExport.markdown(from: Self.sample)
        #expect(
            markdown == "# Plan\nCall the **bank** now\n- milk\n1. first\n- [ ] open\n- [x] done\n",
            "got \(markdown)")
    }

    @Test func htmlGroupsListsAndEscapesText() {
        let text = Self.body("• a < b\n• c\nplain")
        #expect(NotchNoteExport.html(from: text) == "<ul><li>a &lt; b</li><li>c</li></ul><div>plain</div>")
        #expect(NotchNoteExport.html(from: Self.sample).hasPrefix("<h1>Plan</h1><div>Call the <b>bank</b> now</div>"))
    }

    @Test func fileNamesLeaveOutWhatAFileNameCannotHold() {
        #expect(NotchNoteExport.fileName(for: "Q3: plan/draft", extension: "md") == "Q3- plan-draft.md")
        #expect(NotchNoteExport.fileName(for: "  ", extension: "pdf") == "Note.pdf")
    }

    @Test func aPrintedNoteIsDarkOnWhite() {
        let printed = NotchNoteExport.printable(Self.sample)
        let color = printed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(color == .black)
    }

    // MARK: Today's note

    @Test func todaysNoteIsMadeOnceADay() {
        let (notes, folder, _) = Self.store()
        defer { try? FileManager.default.removeItem(at: folder) }
        let morning = Date(timeIntervalSince1970: 1_800_000_000)
        let first = notes.openToday(now: morning)
        notes.openID = nil
        #expect(notes.openToday(now: morning.addingTimeInterval(3600)) == first)
        #expect(notes.openID == first)
        let tomorrow = notes.openToday(now: morning.addingTimeInterval(24 * 3600))
        #expect(tomorrow != first)
        #expect(notes.notes.count == 2)
    }

    // MARK: Meeting notes

    @Test func aMeetingsNoteIsReusedAndTakesItsWriteUp() {
        let (notes, folder, _) = Self.store()
        defer { try? FileManager.default.removeItem(at: folder) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let id = notes.openMeetingNote(key: "standup@1", title: "Standup", start: start, now: start)
        #expect(notes.text(of: id).string.hasPrefix("Standup\n"))
        notes.openID = nil
        #expect(notes.openMeetingNote(key: "standup@1", title: "Standup", start: start, now: start) == id)
        // Written in during the call, then the write-up lands under it rather than in a note of its own.
        notes.save(NSAttributedString(string: notes.text(of: id).string + "my point"), for: id)
        let saved = notes.saveMeeting(
            title: "Standup", date: start.addingTimeInterval(1800), notes: "Summary:\nAll good", transcript: "hi")
        #expect(saved == id)
        let text = notes.text(of: id).string
        #expect(text.contains("my point") && text.contains("All good") && text.contains("hi"))
        #expect(notes.notes.count == 1)
        // Another meeting has its own note.
        let other = notes.saveMeeting(title: "Review", date: start, notes: nil, transcript: "x")
        #expect(other != id)
    }

    @Test func aLinkedNoteIsFoundByTitleAndTime() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let note = UUID()
        let links = [NotchNotes.MeetingLink(note: note, title: "Standup", start: start)]
        #expect(NotchNotes.linkedNote(in: links, title: "Standup", date: start, existing: [note]) == note)
        #expect(NotchNotes.linkedNote(in: links, title: "Review", date: start, existing: [note]) == nil)
        #expect(
            NotchNotes.linkedNote(in: links, title: "Standup", date: start.addingTimeInterval(86400), existing: [note])
                == nil, "the next day's")
        #expect(NotchNotes.linkedNote(in: links, title: "Standup", date: start, existing: []) == nil, "deleted")
    }

    // MARK: Pomodoro and calls

    private static func timers() -> NotchTimers {
        NotchTimers(defaults: UserDefaults(suiteName: "NotchNoteExtrasTests.\(UUID())")!, chime: {})
    }

    @Test func aCallPausesThePomodoroAndItsEndResumesIt() {
        let timers = Self.timers()
        let now = Date()
        timers.startPomodoro(now: now)
        timers.callStarted(now: now.addingTimeInterval(60))
        #expect(timers.running?.isPaused == true)
        timers.callEnded(now: now.addingTimeInterval(600))
        #expect(timers.running?.isPaused == false)
        #expect(timers.running?.remaining(at: now.addingTimeInterval(600)) == 24 * 60)
    }

    @Test func aPomodoroPausedByHandStaysPausedAfterACall() {
        let timers = Self.timers()
        timers.startPomodoro()
        timers.pause()
        timers.callStarted()
        timers.callEnded()
        #expect(timers.running?.isPaused == true)
    }

    @Test func aCountdownOrAnOptOutIgnoresCalls() {
        let timers = Self.timers()
        timers.startCountdown(minutes: 5)
        timers.callStarted()
        #expect(timers.running?.isPaused == false)
        timers.startPomodoro()
        timers.options.pausesForCalls = false
        timers.callStarted()
        #expect(timers.running?.isPaused == false)
    }

    @Test func finishedFocusSessionsAddUpForTheDay() {
        let timers = Self.timers()
        let now = Date()
        timers.startPomodoro(now: now)
        timers.advance(now: now.addingTimeInterval(25 * 60 + 1))
        #expect(timers.focusLog.sessions == 1)
        #expect(timers.focusLog.seconds == 25 * 60)
        let day = NotchNotes.dayKey(now)
        let log = NotchTimers.logged(timers.focusLog, adding: 75 * 60, on: day)
        #expect(NotchTimers.focusSummary(log) == "2 sessions · 1h 40m today")
        #expect(NotchTimers.logged(log, adding: 60, on: "2000-01-01").sessions == 1, "a new day starts afresh")
        #expect(NotchTimerPage.focusToday(NotchTimers.FocusLog(day: "2000-01-01", sessions: 3), now: now) == nil)
    }

    @Test func oldPomodoroOptionsPauseForCalls() throws {
        let old = #"{"sound":true,"startsBreaksOnTheirOwn":true,"startsFocusOnItsOwn":false}"#
        let options = try JSONDecoder().decode(NotchTimers.PomodoroOptions.self, from: Data(old.utf8))
        #expect(options.pausesForCalls)
        #expect(!options.startsFocusOnItsOwn)
    }
}
