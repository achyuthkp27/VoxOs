import AppKit
import Foundation
import Testing

@testable import VoxOS

/// The quiet notch and free time, meeting notes filled from the calendar, notes tied to apps,
/// images in notes, dictating into today's note, and focus on a checklist item.
@Suite
@MainActor
struct NotchQuietFocusTests {
    private static let nine = Date(timeIntervalSince1970: 1_800_000_000)

    private static func event(_ id: String, startsIn minutes: Double, length: Double = 30) -> NotchToday.Event {
        let start = nine.addingTimeInterval(minutes * 60)
        return NotchToday.Event(
            id: id, title: id, start: start, end: start.addingTimeInterval(length * 60), isAllDay: false, color: .white)
    }

    private static func store() -> (NotchNotes, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NotchQuietFocus-\(UUID())")
        let defaults = UserDefaults(suiteName: "NotchQuietFocusTests.\(UUID())")!
        return (NotchNotes(folder: folder, defaults: defaults), folder)
    }

    // MARK: Free time and quiet

    @Test func freeTimeRunsToTheNextMeetingWhileNoneIsOn() {
        let later = Self.event("Review", startsIn: 90)
        #expect(NotchToday.freeUntil(in: [later], now: Self.nine) == later.start)
        #expect(NotchToday.freeUntil(in: [Self.event("Now", startsIn: -10), later], now: Self.nine) == nil, "busy")
        #expect(NotchToday.freeUntil(in: [], now: Self.nine) == nil, "nothing ahead")
    }

    @Test func freeTimeIsTheLastThingTheBandSays() {
        let until = Self.nine.addingTimeInterval(3600)
        func content(note: String? = nil, music: Bool = false) -> NotchHome.Content {
            NotchHome.content(
                enabled: true, hasNotch: true, blocked: false, hovered: false, dropping: false, notice: nil,
                timerRunning: false, musicPlaying: music, pinnedNote: note, freeUntil: until)
        }
        #expect(content() == .free(until))
        #expect(content(note: "Shopping") == .note("Shopping"))
        #expect(content(music: true) == .playing)
        #expect(NotchHomeManager.bandKey(.free(until), track: nil, timer: nil) != nil)
    }

    @Test func theFreeTimeReadsInMinutesThenAsATime() {
        #expect(NotchHome.freeDetail(Self.nine.addingTimeInterval(25 * 60), now: Self.nine) == "for 25m")
        #expect(NotchHome.freeDetail(Self.nine.addingTimeInterval(20), now: Self.nine) == "for 1m")
        #expect(NotchHome.freeDetail(Self.nine.addingTimeInterval(2 * 3600), now: Self.nine).hasPrefix("until "))
    }

    @Test func quietUntilTomorrowEndsInTheMorning() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let morning = NotchHome.tomorrowMorning(now: Self.nine, calendar: calendar)
        #expect(morning > Self.nine)
        #expect(calendar.component(.hour, from: morning) == 8)
        #expect(morning.timeIntervalSince(Self.nine) <= 32 * 3600)
    }

    // MARK: Meetings

    @Test func aMeetingNoteStartsWithTheCalendarsDetails() {
        let details = NotchNotes.meetingDetails(
            attendees: ["Sam", "Ana"], agenda: "1. Budget", link: URL(string: "https://zoom.us/j/1")
        ).string
        #expect(details.contains("Attendees\nSam, Ana"))
        #expect(details.contains("Agenda\n1. Budget"))
        #expect(details.contains("https://zoom.us/j/1"))
        #expect(details.hasSuffix("Notes\n"))
        #expect(NotchNotes.meetingDetails(attendees: [], agenda: nil, link: nil).string == "Notes\n")
    }

    @Test func actionItemsAreReadFromTheWriteUp() {
        let summary =
            "## Summary\nWe met.\n## Action items\n- Send the deck by Friday\n- [ ] Book the room\n## Decisions\n- Ship it"
        #expect(NotchNotes.actionItems(from: summary) == ["Send the deck by Friday", "Book the room"])
        #expect(NotchNotes.actionItems(from: "Summary: nothing to do").isEmpty)
    }

    @Test func aRunningLateDraftIsNeverSent() {
        let script = NotchToday.runningLateScript(to: ["a@x.com", "b\"@x.com"], subject: "Late", body: "Hi")
        #expect(script.contains("address:\"a@x.com\""))
        #expect(script.contains("address:\"b\\\"@x.com\""))
        #expect(script.contains("visible:true"))
        #expect(!script.contains("send "))
    }

    // MARK: Notes

    @Test func aNoteShowsWithItsAppOverThePinnedOne() {
        let (notes, folder) = Self.store()
        defer { try? FileManager.default.removeItem(at: folder) }
        let pinned = notes.create()
        notes.save(NSAttributedString(string: "Pinned"), for: pinned)
        notes.togglePin(pinned)
        let xcode = notes.create()
        notes.save(NSAttributedString(string: "Release checklist"), for: xcode)
        notes.show(xcode, with: "com.apple.dt.Xcode")
        #expect(notes.app(of: xcode) == "com.apple.dt.Xcode")
        #expect(notes.bandNoteID(frontApp: "com.apple.dt.Xcode") == xcode)
        #expect(notes.bandLine(frontApp: "com.apple.dt.Xcode") == "Release checklist")
        #expect(notes.bandLine(frontApp: "com.apple.Safari") == "Pinned")
        notes.save(NSAttributedString(string: "Ship list"), for: xcode)
        #expect(notes.bandLine(frontApp: "com.apple.dt.Xcode") == "Ship list")
        notes.delete(xcode)
        #expect(notes.bandNoteID(frontApp: "com.apple.dt.Xcode") == pinned)
    }

    @Test func aNoteWithAnImageIsKeptAsRTFDAndReadBack() throws {
        let (notes, folder) = Self.store()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = notes.create()
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        let text = NSMutableAttributedString(string: "Look:\n")
        text.append(NSAttributedString(attachment: attachment))
        notes.save(text, for: id)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(files == ["\(id.uuidString).rtfd"])
        #expect(notes.text(of: id).containsAttachments)
        // Without the image it is plain RTF again.
        notes.save(NSAttributedString(string: "Look"), for: id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["\(id.uuidString).rtf"])
        let reread = NotchNotes(folder: folder)
        reread.loadIfNeeded()
        #expect(reread.notes.map(\.id) == [id])
    }

    @Test func imagesShrinkToTheNotesWidthNeverGrow() {
        #expect(
            NotchNoteTextView.fitted(CGSize(width: 800, height: 400), width: 400) == CGSize(width: 400, height: 200))
        #expect(NotchNoteTextView.fitted(CGSize(width: 100, height: 50), width: 400) == CGSize(width: 100, height: 50))
    }

    @Test func anExportLeavesImagesOut() {
        let attachment = NSTextAttachment()
        let text = NSMutableAttributedString(string: "Look ", attributes: NotchNoteFormat.bodyAttributes)
        text.append(NSAttributedString(attachment: attachment))
        #expect(NotchNoteExport.markdown(from: text) == "Look\n")
    }

    @Test func dictationIntoTodaysNoteGoesOnItsOwnLineAfterTheTime() throws {
        let (notes, folder) = Self.store()
        defer { try? FileManager.default.removeItem(at: folder) }
        let today = notes.todayNote()
        notes.openID = nil
        notes.beginDictation(into: today, at: Int.max, stamped: true)
        let target = try #require(notes.takeDictation())
        notes.insert(" buy milk ", into: target)
        let text = notes.text(of: today).string
        #expect(text.hasSuffix(" buy milk"))
        #expect(notes.openID == nil, "it stays out of the way")
        let line = NotchNotes.stamped("hello", after: "Monday\nfirst", at: Self.nine)
        #expect(line.hasPrefix("\n") && line.hasSuffix(" hello"))
        #expect(!NotchNotes.stamped("hello", after: "", at: Self.nine).hasPrefix("\n"))
    }

    // MARK: Focus

    @Test func aFocusSessionOnAnItemTicksItWhenItEnds() {
        let (notes, folder) = Self.store()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = notes.create()
        notes.save(NSAttributedString(string: "☐ Write intro\n☐ Edit"), for: id)
        var done: [NotchTimer.FocusTask] = []
        let timers = NotchTimers(
            defaults: UserDefaults(suiteName: "NotchQuietFocusTests.\(UUID())")!, chime: {},
            onTaskDone: { done.append($0) })
        let now = Date()
        let task = NotchTimer.FocusTask(note: id, item: "Write intro")
        timers.startPomodoro(.focus, task: task, now: now)
        #expect(timers.running?.label == "Write intro")
        timers.advance(now: now.addingTimeInterval(25 * 60 + 1))
        #expect(done == [task])
        #expect(timers.running?.task == nil, "the break is for no item")
        notes.tick("Write intro", in: id)
        #expect(notes.text(of: id).string == "☑ Write intro\n☐ Edit")
        notes.tick("Missing", in: id)
        #expect(notes.text(of: id).string == "☑ Write intro\n☐ Edit")
    }

    @Test func theWeekShowsSevenDaysAndOldDaysAreDropped() {
        var history: [String: TimeInterval] = [:]
        for day in 1...40 {
            history = NotchTimers.recorded(history, adding: 60, on: String(format: "2026-01-%02d", day % 31 + 1))
        }
        #expect(history.count <= NotchTimers.historyDays)
        let today = NotchNotes.dayKey(Self.nine)
        let week = NotchTimers.week([today: 1500], endingOn: Self.nine)
        #expect(week.count == 7)
        #expect(week.last?.seconds == 1500)
        #expect(week.first?.seconds == 0)
        #expect(NotchFocusWeek.duration(6000) == "1h 40m")
    }

    @Test func onlyAFocusSessionCountingDownHidesApps() {
        let now = Date()
        let focus = NotchTimer(kind: .focus, label: "Focus", duration: 60, ends: now.addingTimeInterval(60))
        #expect(NotchFocusApps.isFocusing(focus))
        var paused = focus
        paused.pausedRemaining = 30
        #expect(!NotchFocusApps.isFocusing(paused))
        #expect(!NotchFocusApps.isFocusing(NotchTimer(kind: .shortBreak, label: "", duration: 1, ends: now)))
        #expect(!NotchFocusApps.isFocusing(nil))
    }
}
