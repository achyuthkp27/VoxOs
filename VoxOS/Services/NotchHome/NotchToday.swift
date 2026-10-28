import Combine
import EventKit
import Foundation
import SwiftUI

/// The notch's Today page: the next few events and the weather.
///
/// Calendar access is asked for only when the page is first opened, never at launch, with
/// EventKit's full access (macOS 14+). Weather reuses the Agent's Open-Meteo lookup and is
/// fetched at most every half hour.
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

    @Published private(set) var events: [Event] = []
    @Published private(set) var weather: Weather?
    @Published private(set) var calendarAccess: CalendarAccess = NotchToday.currentAccess()

    private let store = EKEventStore()
    private var weatherFetched: Date?
    private var weatherTask: Task<Void, Never>?
    private var changeObserver: NSObjectProtocol?
    private var reloadTask: Task<Void, Never>?

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
        calendarAccess = Self.currentAccess()
        if calendarAccess == .granted { reloadEvents(now: now) }
        if weatherFetched.map({ now.timeIntervalSince($0) > Self.weatherLifetime }) ?? true { fetchWeather() }
    }

    func requestCalendarAccess() {
        Task { @MainActor in
            // No usage description would make this return false at once without asking, and the
            // status would stay notDetermined: the status, not the Bool, is what counts.
            _ = try? await store.requestFullAccessToEvents()
            calendarAccess = Self.currentAccess()
            if calendarAccess == .granted { reloadEvents(now: Date()) }
        }
    }

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
        }
    }

    private func reloadEvents(now: Date) {
        let calendar = Calendar.current
        guard let end = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) else { return }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let found = store.events(matching: predicate).map { event in
            Event(
                id: event.eventIdentifier ?? UUID().uuidString, title: event.title ?? String(localized: "Untitled"),
                start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                color: event.calendar.map { Color(cgColor: $0.cgColor) } ?? .white)
        }
        events = Self.upcoming(found, now: now)
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
