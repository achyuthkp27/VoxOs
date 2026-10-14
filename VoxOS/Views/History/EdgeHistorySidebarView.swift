import SwiftData
import SwiftUI

/// VoiceOS's left-edge history card: a dark, deeply rounded panel with a search pill and a
/// round lock button up top, transcripts grouped under "Today, 16:10"-style headers, each
/// row a round avatar beside a single truncated title line.
struct EdgeHistorySidebarView: View {
    @Query(Self.recentTranscriptionsDescriptor()) private var transcriptions: [Transcription]
    @Environment(\.modelContext) private var modelContext
    @State private var searchText = ""
    /// Trimmed search term, updated once per keystroke so the filter never re-normalises it per row.
    @State private var normalizedQuery = ""
    /// Matches for `query` across the whole history, newest first. `@Query` above is capped at
    /// `fetchLimit`, so searching only it would never find anything older than that.
    @State private var searchResults: (query: String, items: [Transcription])?
    let onSelectTranscription: () -> Void
    @Binding var isPinned: Bool

    private static let rowLimit = 60
    /// The card shows at most `rowLimit` rows; fetching the whole history to pick 60 was
    /// wasted work. Search does not use this list: it runs its own predicate fetch.
    private static let fetchLimit = 200

    private static func recentTranscriptionsDescriptor() -> FetchDescriptor<Transcription> {
        var descriptor = FetchDescriptor<Transcription>(
            sortBy: [SortDescriptor(\Transcription.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = fetchLimit
        return descriptor
    }

    // Palette lifted from the reference: near-black card, charcoal pill, 40% white captions.
    private static let card = Color(red: 0.05, green: 0.05, blue: 0.06)
    private static let pill = Color.white.opacity(0.09)
    private static let hairline = Color.white.opacity(0.08)
    private static let caption = Color.white.opacity(0.42)
    private static let title = Color.white.opacity(0.95)

    private var filteredTranscriptions: [Transcription] {
        guard !normalizedQuery.isEmpty else {
            return Array(transcriptions.prefix(Self.rowLimit))
        }
        let query = normalizedQuery
        if let searchResults, searchResults.query == query {
            return searchResults.items
        }
        // Until the whole-history fetch for this query lands, filter what is already loaded so
        // typing never shows an empty or stale list.
        // Case-insensitive range search instead of lowercasing every transcript per keystroke.
        return
            transcriptions
            .filter {
                $0.text.localizedCaseInsensitiveContains(query)
                    || ($0.enhancedText?.localizedCaseInsensitiveContains(query) ?? false)
            }
            .prefix(Self.rowLimit)
            .map { $0 }
    }

    /// Groups by day; the header carries the newest time in that group, as VoiceOS does.
    /// `id` is the stable day boundary — `label` embeds the newest timestamp and changes
    /// every time a new transcription lands, so it can't be the ForEach identity without
    /// making SwiftUI treat the whole day section as a new view and flicker it.
    private var groupedByDay: [(id: Date, label: String, items: [Transcription])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: filteredTranscriptions) { calendar.startOfDay(for: $0.timestamp) }
        return groups.keys.sorted(by: >).map { day in
            let items = (groups[day] ?? []).sorted { $0.timestamp > $1.timestamp }
            return (id: day, label: Self.groupLabel(day: day, newest: items.first?.timestamp ?? day), items: items)
        }
    }

    // Built once: a DateFormatter per group per render was the single most expensive thing in this view.
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, d MMM"
        return formatter
    }()

    private static func groupLabel(day: Date, newest: Date) -> String {
        let calendar = Calendar.current
        let time = timeFormatter.string(from: newest)
        if calendar.isDateInToday(day) { return String(localized: "Today") + ", " + time }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") + ", " + time }
        return dayFormatter.string(from: day) + ", " + time
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            list
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .liquidGlass(cornerRadius: EdgeHistoryPanel.cornerRadius, tint: Self.card.opacity(0.62))
        .preferredColorScheme(.dark)
        .onChange(of: searchText) { _, newValue in
            normalizedQuery = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Keyed on the newest row and the count as well, so a transcription added or deleted
        // while a search is showing refreshes the matches.
        .task(id: SearchKey(query: normalizedQuery, newestID: transcriptions.first?.id, count: transcriptions.count)) {
            await refreshSearchResults()
        }
    }

    private struct SearchKey: Hashable {
        let query: String
        let newestID: UUID?
        let count: Int
    }

    private func refreshSearchResults() async {
        let query = normalizedQuery
        guard !query.isEmpty else {
            searchResults = nil
            return
        }
        // A short pause so a burst of keystrokes runs one fetch, not one per character.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }

        var descriptor = FetchDescriptor<Transcription>(
            predicate: #Predicate<Transcription> { transcription in
                transcription.text.localizedStandardContains(query)
                    || (transcription.enhancedText?.localizedStandardContains(query) ?? false)
            },
            sortBy: [SortDescriptor(\Transcription.timestamp, order: .reverse)]
        )
        // Newest first and only `rowLimit` rows are shown, so this limit still searches the
        // whole history; it only stops older matches that would never be displayed.
        descriptor.fetchLimit = Self.rowLimit
        // On a failed fetch the list keeps filtering the loaded rows rather than showing nothing.
        guard let items = try? modelContext.fetch(descriptor) else { return }
        searchResults = (query: query, items: items)
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.app(size: 14, weight: .medium))
                    .foregroundStyle(Self.caption)
                ZStack(alignment: .leading) {
                    if searchText.isEmpty {
                        Text("Search")
                            .font(.app(size: 14))
                            .foregroundStyle(Self.caption)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.app(size: 14))
                        .foregroundStyle(Self.title)
                        .tint(.white)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 46)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(Self.pill))

            Button {
                withAnimation(.snappy(duration: 0.2)) { isPinned.toggle() }
            } label: {
                Image(systemName: isPinned ? "lock.fill" : "lock.open")
                    .font(.app(size: 14, weight: .medium))
                    .foregroundStyle(isPinned ? Color.white : Self.title.opacity(0.85))
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(isPinned ? AppTheme.Accent.primary : Self.pill))
            }
            .buttonStyle(.plain)
            .help(isPinned ? "Unpin — the panel will hide when you move away" : "Pin the panel open")
        }
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }

    private var list: some View {
        // Evaluated once per body pass; the `isEmpty` check and the ForEach used to each
        // re-run the whole filter-and-group.
        let groups = groupedByDay
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                if groups.isEmpty {
                    Text("No history yet")
                        .font(.app(size: 13))
                        .foregroundStyle(Self.caption)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 32)
                } else {
                    ForEach(groups, id: \.id) { group in
                        Text(group.label)
                            .font(.app(size: 13.5))
                            .foregroundStyle(Self.caption)
                            .padding(.horizontal, 26)
                            .padding(.top, 14)
                            .padding(.bottom, 10)

                        ForEach(group.items) { transcription in
                            EdgeHistoryRow(transcription: transcription, onSelect: onSelectTranscription)
                        }
                    }
                }
            }
            .padding(.bottom, 22)
        }
        .mask(
            // Content fades out under the rounded bottom edge, as in the reference.
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0), .init(color: .black, location: 0.94),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top, endPoint: .bottom)
        )
    }
}

private struct EdgeHistoryRow: View {
    let transcription: Transcription
    let onSelect: () -> Void
    @State private var isHovering = false

    private var displayTitle: String {
        // An empty or failed enhancement is stored in `enhancedText` too; neither makes a title.
        let enhanced = transcription.enhancedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usableEnhanced = !enhanced.isEmpty && !enhanced.hasPrefix("Enhancement failed")
        let trimmed =
            usableEnhanced ? enhanced : transcription.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Chat session") : trimmed
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                EdgeHistoryAvatar(emoji: transcription.modeEmoji)
                Text(displayTitle)
                    .font(.app(size: 15))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(height: 62)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(isHovering ? 0.06 : 0))
            )
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering } }
    }
}

/// The blue marbled globe VoiceOS draws beside every entry; a mode emoji replaces it when set.
private struct EdgeHistoryAvatar: View {
    let emoji: String?

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    AngularGradient(
                        colors: [
                            Color(red: 0.36, green: 0.52, blue: 0.95), Color(red: 0.80, green: 0.86, blue: 1.0),
                            Color(red: 0.24, green: 0.36, blue: 0.85), Color(red: 0.62, green: 0.74, blue: 1.0),
                            Color(red: 0.36, green: 0.52, blue: 0.95),
                        ],
                        center: .center)
                )
                .overlay(
                    RadialGradient(
                        colors: [Color.white.opacity(0.55), .clear], center: .init(x: 0.3, y: 0.28), startRadius: 0,
                        endRadius: 16
                    )
                    .clipShape(Circle())
                )
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))

            if let emoji, !emoji.isEmpty,
                emoji.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0x7F })
            {
                Text(emoji).font(.system(size: 14))
            }
        }
        .frame(width: 34, height: 34)
    }
}
