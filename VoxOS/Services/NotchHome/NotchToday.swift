import Combine
import EventKit
import Foundation
import SwiftUI

/// The notch's Today page: the next few events and the weather; and, collapsed, a countdown to
/// the next meeting with a way to join it.
///
/// Calendar access is asked for only when the page is first opened, never at launch, with
/// EventKit's full access (macOS 14+). Weather reuses the Agent's Open-Meteo lookup and is
/// fetched at most every half hour. The meeting is found when the calendar changes and at the
/// moments it can change (a meeting coming into its last five minutes, or running out of the
/// five after its start), never by polling.
@MainActor
final class NotchToday: ObservableObject {
    static let shared = NotchToday()

    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let color: Color
        /// A video call's link, from the event's URL, location or notes.
        var joinURL: URL? = nil
    }

    struct Weather: Equatable {
        let temperature: Int
        let high: Int?
        let low: Int?
        let symbol: String
        let conditions: String
        let place: String?
    }

    enum CalendarAccess: Equatable {
        case notDetermined
        case granted
        case denied
    }

    nonisolated static let eventLimit = 3
    static let weatherLifetime: TimeInterval = 30 * 60
    /// The countdown shows from this long before a meeting…
    nonisolated static let meetingLead: TimeInterval = 5 * 60
    /// …until this long after it starts, for joining a little late.
    nonisolated static let meetingGrace: TimeInterval = 5 * 60
    /// Hosts of video calls whose links are a way in.
    nonisolated static let meetingHosts = [
        "zoom.us", "zoomgov.com", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com",
        "whereby.com", "meet.jit.si", "chime.aws", "facetime.apple.com", "gotomeeting.com", "meet.goto.com",
        "bluejeans.com", "around.co", "app.slack.com",
    ]

    @Published private(set) var events: [Event] = []
    @Published private(set) var weather: Weather?
    @Published private(set) var calendarAccess: CalendarAccess = NotchToday.currentAccess()
    /// The meeting about to start, or just started.
    @Published private(set) var meeting: Event?

    private let store = EKEventStore()
    private var weatherFetched: Date?
    private var weatherTask: Task<Void, Never>?
    private var changeObserver: NSObjectProtocol?
    private var reloadTask: Task<Void, Never>?
    private var watchingMeetings = false
    private var meetingTimer: Timer?
    /// A meeting joined or swiped away from the band; it does not come back.
    private var dismissedMeeting: String?

    private init() {
        // The store posts every change twice, about two seconds apart: coalesced into one reload.
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleReload() }
        }
    }

    /// Called when the Today page opens.
    func refresh(now: Date = Date()) {
        // The status read can lag a grant made in this run, so a grant seen here is kept.
        if calendarAccess != .granted { calendarAccess = Self.currentAccess() }
        if calendarAccess == .granted { reloadEvents(now: now) }
        if weatherFetched.map({ now.timeIntervalSince($0) > Self.weatherLifetime }) ?? true { fetchWeather() }
    }

    func requestCalendarAccess() {
        Task { @MainActor in
            // Without a usage description this returns false at once, without asking; with one, it
            // returns the user's answer.
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            // The request's own answer, not the status read, which can lag it.
            calendarAccess = granted ? .granted : Self.currentAccess()
            guard calendarAccess == .granted else { return }
            Self.grantedThisRun = true
            store.reset()
            reloadEvents(now: Date())
        }
    }

    /// Access granted in this run counts before the status read catches up with it.
    private static var grantedThisRun = false
    static var accessGranted: Bool { grantedThisRun || currentAccess() == .granted }

    static func currentAccess() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    // MARK: Events

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.reloadEvents(now: Date())
            self?.checkMeetings()
        }
    }

    private func reloadEvents(now: Date) {
        let calendar = Calendar.current
        guard let end = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) else { return }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let found = store.events(matching: predicate).map(Self.event(from:))
        events = Self.upcoming(found, now: now)
    }

    private static func event(from event: EKEvent) -> Event {
        Event(
            id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? String(localized: "Untitled"),
            start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
            color: event.calendar.map { Color(cgColor: $0.cgColor) } ?? .white,
            joinURL: joinURL(in: [event.url?.absoluteString, event.location, event.notes]))
    }

    /// The first link to a known video-call host, in the order given.
    nonisolated static func joinURL(in texts: [String?]) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        for text in texts.compactMap({ $0 }) where !text.isEmpty {
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let url = match.url, url.scheme == "https" || url.scheme == "http",
                    let host = url.host?.lowercased()
                else { continue }
                if meetingHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return url }
            }
        }
        return nil
    }

    // MARK: Meeting

    /// Notch Home turns this on while the countdown is wanted and calendar access is granted.
    func watchMeetings(_ on: Bool) {
        guard on != watchingMeetings else { return }
        watchingMeetings = on
        if on {
            checkMeetings()
        } else {
            meetingTimer?.invalidate()
            meetingTimer = nil
            meeting = nil
        }
    }

    /// Joined or swiped away: gone until the next meeting.
    func dismissMeeting() {
        guard let meeting else { return }
        dismissedMeeting = meeting.id
        self.meeting = nil
    }

    func join(_ event: Event) {
        guard let url = event.joinURL else { return }
        ActivityTrail.mark("notch meeting joined")
        NSWorkspace.shared.open(url)
        if meeting?.id == event.id { dismissMeeting() }
    }

    private func checkMeetings(now: Date = Date()) {
        meetingTimer?.invalidate()
        meetingTimer = nil
        guard watchingMeetings, calendarAccess == .granted || Self.currentAccess() == .granted,
            let end = Calendar.current.date(byAdding: .hour, value: 12, to: now)
        else {
            if meeting != nil { meeting = nil }
            return
        }
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-Self.meetingGrace), end: end, calendars: nil)
        let candidates = store.events(matching: predicate)
            .filter { event in
                event.status != .canceled
                    && event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
            }
            .map(Self.event(from:))
            .filter { $0.id != dismissedMeeting }
        let (current, next) = Self.meeting(in: candidates, now: now)
        if meeting != current { meeting = current }
        guard let wake = Self.nextCheck(current: current, next: next, now: now) else { return }
        let timer = Timer(fire: wake, interval: 0, repeats: false) { _ in
            Task { @MainActor in NotchToday.shared.checkMeetings() }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        meetingTimer = timer
    }

    /// The meeting to count down to (within its lead, or its grace after starting, and not over)
    /// and the next one after that; all-day events are not meetings.
    nonisolated static func meeting(in events: [Event], now: Date) -> (current: Event?, next: Event?) {
        let timed = events.filter { !$0.isAllDay }.sorted { $0.start < $1.start }
        let current = timed.first {
            now >= $0.start.addingTimeInterval(-meetingLead) && now < $0.start.addingTimeInterval(meetingGrace)
                && now < $0.end
        }
        let next = timed.first { $0.start.addingTimeInterval(-meetingLead) > now }
        return (current, next)
    }

    /// When the answer can next change: the shown meeting running out, or the next one coming in.
    nonisolated static func nextCheck(current: Event?, next: Event?, now: Date) -> Date? {
        [
            current.map { min($0.start.addingTimeInterval(meetingGrace), $0.end) },
            next.map { $0.start.addingTimeInterval(-meetingLead) },
        ]
        .compactMap { $0 }
        .filter { $0 > now }
        .min()
    }

    /// The Calendar page offers Join from a few minutes before a call until it ends.
    nonisolated static func canJoin(_ event: Event, now: Date) -> Bool {
        event.joinURL != nil && now >= event.start.addingTimeInterval(-2 * meetingLead) && now < event.end
    }

    /// "4m" before the start, rounded up so it never says 0; "now" from the start.
    nonisolated static func countdown(to start: Date, now: Date) -> String {
        let seconds = start.timeIntervalSince(now)
        guard seconds > 0 else { return String(localized: "now") }
        return String(localized: "\(Int((seconds / 60).rounded(.up)))m")
    }

    /// What is left of today, then tomorrow; timed events before all-day ones, earliest first.
    nonisolated static func upcoming(_ events: [Event], now: Date, limit: Int = eventLimit) -> [Event] {
        events
            .filter { $0.end > now }
            .sorted { lhs, rhs in
                if lhs.isAllDay != rhs.isAllDay { return !lhs.isAllDay }
                return lhs.start < rhs.start
            }
            .prefix(limit)
            .map { $0 }
    }

    /// "Now", "in 25 min", "14:30", "Tomorrow 09:00", "All day".
    nonisolated static func when(_ event: Event, now: Date, calendar: Calendar = .current) -> String {
        if event.isAllDay { return String(localized: "All day") }
        if event.start <= now { return String(localized: "Now") }
        let minutes = Int(event.start.timeIntervalSince(now) / 60)
        if minutes < 60 { return String(localized: "in \(minutes) min") }
        let time = event.start.formatted(date: .omitted, time: .shortened)
        return calendar.isDate(event.start, inSameDayAs: now) ? time : String(localized: "Tomorrow \(time)")
    }

    // MARK: Weather

    private func fetchWeather() {
        weatherTask?.cancel()
        weatherTask = Task { @MainActor [weak self] in
            let summary = await AgentWeather.current()
            guard !Task.isCancelled, let self else { return }
            if let weather = Self.weather(from: summary) {
                self.weather = weather
                self.weatherFetched = Date()
            }
        }
    }

    nonisolated static func weather(from summary: [String: Any]) -> Weather? {
        guard let temperature = summary["temperature_c"] as? Double else { return nil }
        let conditions = summary["conditions"] as? String ?? ""
        let today = (summary["outlook"] as? [[String: Any]])?.first
        return Weather(
            temperature: Int(temperature.rounded()), high: (today?["high_c"] as? Double).map { Int($0.rounded()) },
            low: (today?["low_c"] as? Double).map { Int($0.rounded()) }, symbol: symbol(for: conditions),
            conditions: conditions, place: summary["place"] as? String)
    }

    nonisolated static func symbol(for conditions: String) -> String {
        let text = conditions.lowercased()
        if text.contains("thunder") { return "cloud.bolt.rain.fill" }
        if text.contains("snow") { return "cloud.snow.fill" }
        if text.contains("rain") || text.contains("drizzle") || text.contains("shower") { return "cloud.rain.fill" }
        if text.contains("fog") { return "cloud.fog.fill" }
        if text.contains("overcast") { return "cloud.fill" }
        if text.contains("partly") || text.contains("mainly") { return "cloud.sun.fill" }
        if text.contains("clear") { return "sun.max.fill" }
        return "cloud.fill"
    }
}
