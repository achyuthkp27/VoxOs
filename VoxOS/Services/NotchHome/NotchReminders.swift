import Combine
import EventKit
import Foundation
import SwiftUI

/// The notch's Reminders page: what is still open, soonest due first, ticked off in place.
///
/// Access is asked for only from the page itself, with EventKit's full access to reminders
/// (macOS 14+). A tick saves straight to Reminders, so it shows on every device at once.
@MainActor
final class NotchReminders: ObservableObject {
    static let shared = NotchReminders()

    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let due: Date?
        let color: Color
    }

    nonisolated static let limit = 4

    @Published private(set) var items: [Item] = []
    @Published private(set) var access: NotchToday.CalendarAccess = NotchReminders.currentAccess()

    private let store = EKEventStore()
    private var changeObserver: NSObjectProtocol?
    private var reloadTask: Task<Void, Never>?

    private init() {
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleReload() }
        }
    }

    static func currentAccess() -> NotchToday.CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    func refresh() {
        access = Self.currentAccess()
        if access == .granted { reload() }
    }

    func requestAccess() {
        Task { @MainActor in
            _ = try? await store.requestFullAccessToReminders()
            access = Self.currentAccess()
            if access == .granted { reload() }
        }
    }

    func complete(_ id: String) {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        reminder.isCompleted = true
        try? store.save(reminder, commit: true)
        items.removeAll { $0.id == id }
        scheduleReload()
    }

    private func scheduleReload() {
        reloadTask?.cancel()
        reloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    private func reload() {
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: predicate) { reminders in
            let found = (reminders ?? []).map { reminder in
                Item(
                    id: reminder.calendarItemIdentifier, title: reminder.title ?? "",
                    due: reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) },
                    color: reminder.calendar.map { Color(cgColor: $0.cgColor) } ?? .white)
            }
            Task { @MainActor in NotchReminders.shared.items = Self.ordered(found) }
        }
    }

    /// Due ones first, earliest first (overdue at the top); then the rest, in the order given.
    nonisolated static func ordered(_ items: [Item], limit: Int = limit) -> [Item] {
        let dated = items.filter { $0.due != nil && !$0.title.isEmpty }.sorted { $0.due! < $1.due! }
        let undated = items.filter { $0.due == nil && !$0.title.isEmpty }
        return Array((dated + undated).prefix(limit))
    }

    /// "Overdue", "Today 17:00", "Tomorrow", "Fri", or nothing for an undated reminder.
    nonisolated static func when(_ item: Item, now: Date, calendar: Calendar = .current) -> String? {
        guard let due = item.due else { return nil }
        if due < now, !calendar.isDate(due, inSameDayAs: now) { return String(localized: "Overdue") }
        if calendar.isDate(due, inSameDayAs: now) {
            let hasTime = calendar.component(.hour, from: due) != 0 || calendar.component(.minute, from: due) != 0
            return hasTime
                ? String(localized: "Today \(due.formatted(date: .omitted, time: .shortened))")
                : String(localized: "Today")
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(due, inSameDayAs: tomorrow)
        {
            return String(localized: "Tomorrow")
        }
        return due.formatted(.dateTime.weekday(.abbreviated).day())
    }
}
