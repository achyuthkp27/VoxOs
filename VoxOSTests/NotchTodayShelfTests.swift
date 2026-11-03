import Foundation
import SwiftUI
import Testing

@testable import VoxOS

/// Today, the shelf and device notices: the parts that decide what a glance at the notch says.
@Suite
@MainActor
struct NotchTodayShelfTests {

    // MARK: Today

    private func event(
        _ title: String, start: TimeInterval, length: TimeInterval = 1_800, allDay: Bool = false, from now: Date
    )
        -> NotchToday.Event
    {
        NotchToday.Event(
            id: title, title: title, start: now.addingTimeInterval(start),
            end: now.addingTimeInterval(start + length), isAllDay: allDay, color: .white)
    }

    /// A fixed noon, so the tests read the same whatever the hour they run.
    private var noon: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12))!
    }

    @Test func aDaysEventsAreAllDayFirstThenByStart() {
        let now = noon
        let events = [
            event("Later", start: 7_200, from: now),
            event("Tomorrow", start: 86_400, from: now),
            event("Holiday", start: -12 * 3_600, length: 86_400, allDay: true, from: now),
            event("Morning", start: -3 * 3_600, from: now),
            event("Overnight", start: -86_400 + 3_600, length: 86_400, from: now),
        ]
        let titles = NotchToday.events(events, on: now).map(\.title)
        #expect(titles == ["Holiday", "Overnight", "Morning", "Later"], "the day's own, past ones kept")
    }

    @Test func anEventEndingAtMidnightIsNotOnTheNextDay() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: noon)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let late = NotchToday.Event(
            id: "late", title: "late", start: tomorrow.addingTimeInterval(-3_600), end: tomorrow, isAllDay: false,
            color: .white)
        #expect(NotchToday.event(late, isOn: today))
        #expect(!NotchToday.event(late, isOn: tomorrow))
    }

    @Test func busyDaysAreTheStripsDaysWithAnEvent() {
        let calendar = Calendar.current
        let days = NotchToday.stripDays(around: noon)
        #expect(days.count == 2 * NotchToday.stripReach + 1)
        #expect(days[NotchToday.stripReach] == calendar.startOfDay(for: noon), "the day itself in the middle")
        let busy = NotchToday.busyDays([event("A", start: 2 * 86_400, from: noon)], in: days)
        #expect(busy == [calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: noon))!])
    }

    @Test func timeRangeIsAllDayOrStartAndEnd() {
        let now = noon
        #expect(NotchToday.timeRange(event("A", start: 0, allDay: true, from: now), on: now) == ["All day"])
        let range = NotchToday.timeRange(event("B", start: 0, length: 3_600, from: now), on: now)
        #expect(range.count == 2)
        #expect(range[0].hasSuffix(" -"))
    }

    @Test func weatherComesFromTheAgentsSummary() {
        let summary: [String: Any] = [
            "temperature_c": 23.6, "conditions": "partly cloudy", "place": "Bengaluru",
            "outlook": [["day": "today", "high_c": 29.2, "low_c": 19.8]],
        ]
        let weather = NotchToday.weather(from: summary)
        #expect(weather?.temperature == 24)
        #expect(weather?.high == 29)
        #expect(weather?.low == 20)
        #expect(weather?.symbol == "cloud.sun.fill")
        #expect(NotchToday.weather(from: ["error": "no location"]) == nil)
        #expect(NotchToday.symbol(for: "thunderstorm with hail") == "cloud.bolt.rain.fill")
        #expect(NotchToday.symbol(for: "light drizzle") == "cloud.rain.fill")
    }

    // MARK: Shelf

    private func shelf(existing: Set<String>) -> NotchShelf {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-\(UUID().uuidString).json")
        return NotchShelf(storeURL: url, fileExists: { existing.contains($0) })
    }

    @Test func theShelfKeepsNewestFirstWithoutDuplicates() {
        let shelf = shelf(existing: ["/a.pdf", "/b.png"])
        shelf.add([URL(fileURLWithPath: "/a.pdf")])
        shelf.add([URL(fileURLWithPath: "/b.png")])
        shelf.add([URL(fileURLWithPath: "/a.pdf")])
        #expect(shelf.items.map(\.path) == ["/a.pdf", "/b.png"], "a file dropped again moves to the front")
        shelf.add([URL(fileURLWithPath: "/missing.txt")])
        #expect(shelf.items.count == 2, "a file that is not there is not shelved")
    }

    @Test func theShelfHasALimitAndSurvivesARelaunch() {
        let paths = (0..<(NotchShelf.limit + 3)).map { "/file\($0)" }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-\(UUID().uuidString).json")
        let first = NotchShelf(storeURL: url, fileExists: { _ in true })
        first.add(paths.map { URL(fileURLWithPath: $0) })
        #expect(first.items.count == NotchShelf.limit)
        let second = NotchShelf(storeURL: url, fileExists: { _ in true })
        #expect(second.items == first.items)
        let pruned = NotchShelf(storeURL: url, fileExists: { $0 != first.items[0].path })
        #expect(pruned.items.count == NotchShelf.limit - 1, "a deleted file leaves the shelf")
    }

    // MARK: Device notices

    @Test func oneConnectGivesOneNotice() {
        let start = Date()
        #expect(NotchDeviceAlerts.shouldShow(key: "bt-x-true", at: start, last: nil))
        #expect(
            !NotchDeviceAlerts.shouldShow(key: "bt-x-true", at: start.addingTimeInterval(1), last: start),
            "the same connect fires several callbacks")
        #expect(
            NotchDeviceAlerts.shouldShow(
                key: "bt-x-true", at: start.addingTimeInterval(NotchDeviceAlerts.repeatWindow), last: start))
    }

    /// Icons come from the class a device reports, whatever its owner named it.
    @Test func devicesGetTheirOwnIcon() {
        func symbol(_ name: String, _ major: UInt32, _ minor: UInt32) -> String {
            NotchDeviceAlerts.symbol(name: name, majorClass: major, minorClass: minor)
        }
        #expect(symbol("AirPods Pro", 0x04, 0x01) == "airpodspro", "only Apple's earbuds need their name")
        #expect(symbol("Buds", 0x04, 0x01) == "earbuds", "a headset")
        #expect(symbol("Any name", 0x04, 0x06) == "headphones")
        #expect(symbol("Any name", 0x04, 0x05) == "hifispeaker.fill")
        #expect(symbol("Any name", 0x05, 0x10) == "keyboard")
        #expect(symbol("Any name", 0x05, 0x20) == "computermouse")
        #expect(symbol("Any name", 0x05, 0x02) == "gamecontroller")
        #expect(symbol("Keyboard", 0x1F, 0) == "dot.radiowaves.left.and.right", "a name alone decides nothing")
    }

    // MARK: Reminders

    @Test func remindersShowDueOnesFirstThenTheRest() {
        let now = Date()
        func item(_ title: String, due: TimeInterval?) -> NotchReminders.Item {
            NotchReminders.Item(id: title, title: title, due: due.map { now.addingTimeInterval($0) }, color: .white)
        }
        let ordered = NotchReminders.ordered(
            [item("Someday", due: nil), item("Later", due: 7_200), item("Late", due: -90_000), item("", due: 60)],
            limit: 4)
        #expect(ordered.map(\.title) == ["Late", "Later", "Someday"], "overdue first, untitled dropped")
    }

    @Test func aDaysRemindersAndWhatTheySay() {
        let now = noon
        func item(_ title: String, due: TimeInterval?) -> NotchReminders.Item {
            NotchReminders.Item(id: title, title: title, due: due.map { now.addingTimeInterval($0) }, color: .white)
        }
        let all = [
            item("Late", due: -2 * 86_400), item("Soon", due: 3_600), item("Someday", due: nil),
            item("Friday", due: 3 * 86_400),
        ]
        #expect(NotchReminders.items(all, on: now, now: now).map(\.title) == ["Late", "Soon", "Someday"])
        let friday = now.addingTimeInterval(3 * 86_400)
        #expect(NotchReminders.items(all, on: friday, now: now).map(\.title) == ["Friday"])
        #expect(NotchReminders.dueLabel(all[0], now: now) == "Overdue")
        #expect(NotchReminders.dueLabel(all[2], now: now) == "Anytime")
        #expect(NotchReminders.isOverdue(all[0], now: now))
        #expect(!NotchReminders.isOverdue(all[1], now: now))
        #expect(NotchReminders.isOverdue(item("Earlier", due: -3_600), now: now), "a time today gone by")
    }

    // MARK: Shelf details

    @Test func shelfDetailsAreReadFromTheFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-\(UUID().uuidString).txt")
        try Data(repeating: 65, count: 2_048).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let details = NotchShelf.details(of: NotchShelf.Item(id: UUID(), path: url.path, added: Date()))
        #expect(details.size == 2_048)
        #expect(details.kind?.isEmpty == false)
        #expect(details.summary.contains("·"))
    }

    @Test func pagesWalkInTheAskedOrder() {
        // The order asked for, then the pages added later, each behind its own switch.
        #expect(NotchHomePage.allCases == [.music, .today, .weather, .timer, .shelf, .sound])
        #expect(NotchHomePage.timer.title == "Pomodoro")
        #expect(NotchHomePage.today.title == "Calendar")
    }
}
