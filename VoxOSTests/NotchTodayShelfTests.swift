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

    @Test func upcomingIsWhatIsLeftTimedFirst() {
        let now = Date()
        let events = [
            event("Holiday", start: -3_600, length: 86_400, allDay: true, from: now),
            event("Later", start: 7_200, from: now),
            event("Over", start: -7_200, from: now),
            event("Soon", start: 600, from: now),
            event("Going on", start: -600, from: now),
        ]
        let titles = NotchToday.upcoming(events, now: now, limit: 3).map(\.title)
        #expect(titles == ["Going on", "Soon", "Later"], "finished ones gone, all-day after timed")
    }

    @Test func whenReadsLikeAGlance() {
        let now = Date()
        #expect(NotchToday.when(event("A", start: -60, from: now), now: now) == "Now")
        #expect(NotchToday.when(event("B", start: 25 * 60, from: now), now: now) == "in 25 min")
        #expect(NotchToday.when(event("C", start: 0, allDay: true, from: now), now: now) == "All day")
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
        #expect(NotchReminders.when(item("Late", due: -90_000), now: now) == "Overdue")
        #expect(NotchReminders.when(item("Someday", due: nil), now: now) == nil)
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
        #expect(NotchHomePage.allCases == [.music, .today, .reminders, .timer, .shelf])
        #expect(NotchHomePage.timer.title == "Pomodoro")
        #expect(NotchHomePage.today.title == "Calendar")
    }
}
