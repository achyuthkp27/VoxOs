import AppKit
import CoreAudio
import SwiftUI
import UniformTypeIdentifiers

/// The Calendar page: the month beside a row of days, the picked one in the middle; under them
/// that day as an agenda — all-day events as chips, timed ones on a time column with their
/// calendar's bar, and the reminders on the same grid.
struct NotchTodayPage: View {
    @ObservedObject var today: NotchToday
    @ObservedObject var reminders: NotchReminders
    /// Told how tall the list is, so the card can fit it.
    var onListHeight: (CGFloat) -> Void = { _ in }

    static let stripHeight: CGFloat = 52
    /// The rule under the strip, with its space above and below.
    static let ruleSpace: CGFloat = 19
    /// The width of the time column, where events start and reminders are due.
    static let timeWidth: CGFloat = 52
    /// The width of the column holding each event's bar and each reminder's ring.
    static let markWidth: CGFloat = 15

    /// The list at its shortest, a single line…
    static var minimumListHeight: CGFloat { 30 }
    /// …and at its tallest; past that it scrolls.
    static var maximumListHeight: CGFloat { 196 }

    /// The card's height on this page: the strip, and the list under it, fitted to what it holds.
    static func cardHeight(list: CGFloat) -> CGFloat {
        let fitted = min(max(list, minimumListHeight), maximumListHeight)
        return NotchHome.Card.top + 4 + stripHeight + ruleSpace + fitted + NotchHome.Card.bottom + 6
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 0) {
                header(now: context.date)
                    .frame(height: Self.stripHeight)
                Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                    .padding(.top, 9).padding(.bottom, Self.ruleSpace - 10)
                ScrollView(.vertical) {
                    agenda(now: context.date)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.height.rounded(.up)
                        } action: { height in
                            onListHeight(height)
                        }
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, AgentComposer.panelInset)
        .padding(.bottom, NotchHome.Card.bottom)
        .onAppear {
            today.refresh()
            reminders.refresh()
        }
    }

    // MARK: Strip

    private func header(now: Date) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                today.select(now)
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: today.selectedDay.formatted(.dateTime.month(.abbreviated)))
                        .font(.app(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                    Text(verbatim: today.selectedDay.formatted(.dateTime.year()))
                        .font(.app(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 58, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Today"))
            .accessibilityLabel(Text("Go to today"))
            NotchWeekStrip(
                selected: today.selectedDay, busy: busyDays, now: now, onSelect: { today.select($0) })
        }
    }

    /// Days with an event or a reminder due.
    private var busyDays: Set<Date> {
        let days = NotchToday.stripDays(around: today.selectedDay)
        return today.busyDays.union(NotchReminders.dueDays(reminders.items, in: days))
    }

    // MARK: Agenda

    @ViewBuilder
    private func agenda(now: Date) -> some View {
        let day = today.selectedDay
        let events = today.calendarAccess == .granted ? today.dayEvents : []
        let allDay = events.filter(\.isAllDay)
        let timed = events.filter { !$0.isAllDay }
        let items = reminders.access == .granted ? NotchReminders.items(reminders.items, on: day, now: now) : []
        VStack(alignment: .leading, spacing: 0) {
            calendarAccessPrompt
            if !allDay.isEmpty {
                NotchAllDayRow(events: allDay)
                    .padding(.bottom, timed.isEmpty ? 0 : 10)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(timed) { event in
                    NotchAgendaEvent(
                        event: event, day: day, now: now, canJoin: NotchToday.canJoin(event, now: now),
                        onJoin: { today.join(event) })
                }
            }
            if !items.isEmpty {
                NotchAgendaSection(title: String(localized: "Reminders"), count: items.count)
                    .padding(.top, events.isEmpty ? 0 : 12)
                    .padding(.bottom, 8)
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(items) { item in
                        NotchAgendaReminder(item: item, now: now) { reminders.complete(item.id) }
                    }
                }
            }
            remindersAccessPrompt
                .padding(.top, events.isEmpty ? 0 : 12)
            if events.isEmpty, items.isEmpty, today.calendarAccess == .granted, reminders.access == .granted {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(NotchDayCell.accent)
                    (Calendar.current.isDate(day, inSameDayAs: now)
                        ? Text("Nothing planned today") : Text("Nothing planned"))
                        .font(.app(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .padding(.leading, Self.timeWidth + 10)
                .frame(height: Self.minimumListHeight, alignment: .center)
            }
        }
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var calendarAccessPrompt: some View {
        switch today.calendarAccess {
        case .notDetermined:
            NotchAccessPrompt(title: String(localized: "See what's on")) {
                NotchChip(title: String(localized: "Allow Calendar"), prominent: true) {
                    today.requestCalendarAccess()
                }
            }
        case .denied:
            NotchAccessPrompt(title: String(localized: "Calendar access is off")) {
                NotchChip(title: String(localized: "Open Settings")) {
                    openPrivacySettings("Privacy_Calendars")
                }
            }
        case .granted:
            EmptyView()
        }
    }

    @ViewBuilder
    private var remindersAccessPrompt: some View {
        switch reminders.access {
        case .notDetermined:
            NotchAccessPrompt(title: String(localized: "See what's left to do")) {
                NotchChip(title: String(localized: "Allow Reminders"), prominent: true) { reminders.requestAccess() }
            }
        case .denied:
            NotchAccessPrompt(title: String(localized: "Reminders access is off")) {
                NotchChip(title: String(localized: "Open Settings")) {
                    openPrivacySettings("Privacy_Reminders")
                }
            }
        case .granted:
            EmptyView()
        }
    }
}

/// The row of days: as many as fit, the selected one in the middle on a filled tile. A click
/// picks a day and the row centres on it; it never scrolls, so a sideways swipe still turns the page.
private struct NotchWeekStrip: View {
    let selected: Date
    let busy: Set<Date>
    let now: Date
    let onSelect: (Date) -> Void

    static let minimumCellWidth: CGFloat = 46

    var body: some View {
        GeometryReader { proxy in
            let count = Self.cellCount(for: proxy.size.width)
            HStack(spacing: 0) {
                ForEach(days(count: count), id: \.self) { day in
                    NotchDayCell(
                        day: day, isSelected: day == selected,
                        isToday: Calendar.current.isDate(day, inSameDayAs: now),
                        isBusy: busy.contains(day)
                    ) { onSelect(day) }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .animation(.snappy(duration: 0.28), value: selected)
        }
    }

    /// An odd number, so one day sits in the middle.
    static func cellCount(for width: CGFloat) -> Int {
        let fit = max(5, Int(width / minimumCellWidth))
        return fit.isMultiple(of: 2) ? fit - 1 : fit
    }

    private func days(count: Int) -> [Date] {
        NotchToday.stripDays(around: selected, reach: min(count / 2, NotchToday.stripReach))
    }
}

/// A day in the row: its weekday over its date, and a dot when something is on. The selected day
/// sits on a filled tile; today, when another day is picked, keeps its date in the accent.
private struct NotchDayCell: View {
    let day: Date
    let isSelected: Bool
    let isToday: Bool
    let isBusy: Bool
    let action: () -> Void
    @State private var hovered = false

    static let accent = Color(nsColor: .systemBlue)

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(verbatim: weekday)
                    .font(.app(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(isSelected ? 1 : 0.4))
                Text(verbatim: day.formatted(.dateTime.day()))
                    .font(.app(size: 17, weight: isSelected ? .bold : .medium, design: .rounded))
                    .foregroundStyle(numberColor)
                Circle()
                    .fill(isSelected ? .white : Self.accent)
                    .frame(width: 4, height: 4)
                    .opacity(isBusy ? 1 : 0)
            }
            .frame(width: 38, height: 52)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Self.accent : .white.opacity(hovered ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(Text(verbatim: day.formatted(date: .complete, time: .omitted)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The selected day spells out its weekday; the others give a letter.
    private var weekday: String {
        isSelected
            ? day.formatted(.dateTime.weekday(.abbreviated)).uppercased()
            : day.formatted(.dateTime.weekday(.narrow))
    }

    private var numberColor: Color {
        if isSelected { return .white }
        if isToday { return Self.accent }
        if Calendar.current.isDateInWeekend(day) { return Color(red: 1, green: 0.5, blue: 0.5).opacity(0.8) }
        return .white.opacity(0.75)
    }
}

/// All-day events as chips in their calendar's colour, beside the time column's "All day".
private struct NotchAllDayRow: View {
    let events: [NotchToday.Event]
    static let shown = 3

    var body: some View {
        HStack(spacing: 6) {
            Text("All day")
                .textCase(.uppercase)
                .font(.app(size: 9.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: NotchTodayPage.timeWidth, alignment: .trailing)
                .padding(.trailing, 4)
            ForEach(events.prefix(Self.shown)) { event in
                HStack(spacing: 5) {
                    Circle().fill(event.color).frame(width: 6, height: 6)
                    Text(verbatim: event.title)
                        .font(.app(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(Capsule().fill(event.color.opacity(0.2)))
                .help(Text(verbatim: event.title))
            }
            if events.count > Self.shown {
                Text(verbatim: "+\(events.count - Self.shown)")
                    .font(.app(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }
}

/// A timed event: when it starts and ends, its calendar's bar — filling as it runs — and its title
/// over where it is and how soon.
private struct NotchAgendaEvent: View {
    let event: NotchToday.Event
    let day: Date
    let now: Date
    let canJoin: Bool
    let onJoin: () -> Void

    var body: some View {
        let progress = NotchToday.progress(event, now: now)
        let detail = NotchToday.detail(event, now: now)
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(verbatim: NotchToday.shortTime(event.start, on: day))
                    .font(.app(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text(verbatim: NotchToday.shortTime(event.end, on: day))
                    .font(.app(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: NotchTodayPage.timeWidth, alignment: .trailing)
            ZStack(alignment: .top) {
                Capsule().fill(event.color.opacity(progress == nil ? 1 : 0.3))
                if let progress {
                    GeometryReader { proxy in
                        Capsule().fill(event.color).frame(height: max(3, proxy.size.height * progress))
                    }
                }
            }
            .frame(width: 3)
            .frame(width: NotchTodayPage.markWidth)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: event.title)
                        .font(.app(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if progress != nil {
                        Text("Now")
                            .textCase(.uppercase)
                            .font(.app(size: 9, weight: .bold))
                            .tracking(0.5)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .frame(height: 15)
                            .background(Capsule().fill(event.color))
                            .fixedSize()
                    }
                }
                if !detail.isEmpty {
                    Text(verbatim: detail)
                        .font(.app(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if canJoin { NotchJoinButton(action: onJoin).padding(.top, 2) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .opacity(event.end <= now ? 0.4 : 1)
    }
}

/// A small header in the agenda: its title, a count, and a rule to the edge.
private struct NotchAgendaSection: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: title.uppercased())
                .font(.app(size: 9.5, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.4))
            Text(verbatim: "\(count)")
                .font(.app(size: 9.5, weight: .bold))
                .foregroundStyle(.white.opacity(0.6))
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
        }
    }
}

/// A reminder on the agenda's grid: when it is due in the time column, a ring to tick where the
/// events have their bar, and its title.
private struct NotchAgendaReminder: View {
    let item: NotchReminders.Item
    let now: Date
    let onComplete: () -> Void
    @State private var hovered = false

    var body: some View {
        let overdue = NotchReminders.isOverdue(item, now: now)
        HStack(spacing: 10) {
            Text(verbatim: NotchReminders.dueLabel(item, now: now))
                .font(.app(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(overdue ? Color(red: 1, green: 0.45, blue: 0.4) : .white.opacity(0.4))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: NotchTodayPage.timeWidth, alignment: .trailing)
            Button(action: onComplete) {
                ZStack {
                    Circle().strokeBorder(item.color, lineWidth: 1.5)
                    if hovered {
                        Image(systemName: "checkmark")
                            .font(.system(size: 7, weight: .heavy))
                            .foregroundStyle(item.color)
                    }
                }
                .frame(width: NotchTodayPage.markWidth, height: NotchTodayPage.markWidth)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityLabel(Text("Complete \(item.title)"))
            Text(verbatim: item.title)
                .font(.app(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .help(Text(verbatim: item.title))
            Spacer(minLength: 0)
        }
    }
}

/// Asking for Calendar or Reminders access, from the page itself.
private struct NotchAccessPrompt<Action: View>: View {
    let title: String
    let action: Action

    init(title: String, @ViewBuilder action: () -> Action) {
        self.title = title
        self.action = action()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title)
                .font(.app(size: 13, weight: .semibold))
                .foregroundStyle(.white)
            action
        }
        .padding(.leading, NotchTodayPage.timeWidth + 10)
    }
}

/// Opens a pane of System Settings → Privacy & Security, such as "Privacy_Calendars".
@MainActor
private func openPrivacySettings(_ pane: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Shelf
