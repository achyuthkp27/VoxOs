import SwiftData
import SwiftUI

/// VoiceOS's left-edge history card: a dark, deeply rounded panel with a search pill and a
/// round lock button up top, transcripts grouped under "Today, 16:10"-style headers, each
/// row a round avatar beside a single truncated title line.
struct EdgeHistorySidebarView: View {
    @Query(sort: \Transcription.timestamp, order: .reverse) private var transcriptions: [Transcription]
    @State private var searchText = ""
    let onSelectTranscription: () -> Void
    @Binding var isPinned: Bool

    private static let rowLimit = 60

    // Palette lifted from the reference: near-black card, charcoal pill, 40% white captions.
    private static let card = Color(red: 0.05, green: 0.05, blue: 0.06)
    private static let pill = Color.white.opacity(0.09)
    private static let hairline = Color.white.opacity(0.08)
    private static let caption = Color.white.opacity(0.42)
    private static let title = Color.white.opacity(0.95)

    private var filteredTranscriptions: [Transcription] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Array(transcriptions.prefix(Self.rowLimit))
        }
        let query = searchText.lowercased()
        return transcriptions
            .filter { $0.text.lowercased().contains(query) || ($0.enhancedText?.lowercased().contains(query) ?? false) }
            .prefix(Self.rowLimit)
            .map { $0 }
    }

    /// Groups by day; the header carries the newest time in that group, as VoiceOS does.
    private var groupedByDay: [(label: String, items: [Transcription])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: filteredTranscriptions) { calendar.startOfDay(for: $0.timestamp) }
        return groups.keys.sorted(by: >).map { day in
            let items = (groups[day] ?? []).sorted { $0.timestamp > $1.timestamp }
            return (label: Self.groupLabel(day: day, newest: items.first?.timestamp ?? day), items: items)
        }
    }

    private static func groupLabel(day: Date, newest: Date) -> String {
        let calendar = Calendar.current
        let time = DateFormatter()
        time.dateFormat = "HH:mm"
        if calendar.isDateInToday(day) { return String(localized: "Today") + ", " + time.string(from: newest) }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") + ", " + time.string(from: newest) }
        let date = DateFormatter()
        date.dateFormat = "EEE, d MMM"
        return date.string(from: day) + ", " + time.string(from: newest)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            list
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .liquidGlass(cornerRadius: EdgeHistoryPanel.cornerRadius, tint: Self.card.opacity(0.62))
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.app(size: 15, weight: .medium))
                    .foregroundStyle(Self.caption)
                ZStack(alignment: .leading) {
                    if searchText.isEmpty {
                        Text("Search")
                            .font(.app(size: 16))
                            .foregroundStyle(Self.caption)
                            .allowsHitTesting(false)
                    }
                    TextField("", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.app(size: 16))
                        .foregroundStyle(Self.title)
                        .tint(.white)
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 46)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(Self.pill))

            Button { withAnimation(.snappy(duration: 0.2)) { isPinned.toggle() } } label: {
                Image(systemName: isPinned ? "lock.fill" : "lock.open")
                    .font(.app(size: 15, weight: .medium))
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
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                if groupedByDay.isEmpty {
                    Text("No history yet")
                        .font(.app(size: 14))
                        .foregroundStyle(Self.caption)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 32)
                } else {
                    ForEach(groupedByDay, id: \.label) { group in
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
                stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                startPoint: .top, endPoint: .bottom)
        )
    }
}

private struct EdgeHistoryRow: View {
    let transcription: Transcription
    let onSelect: () -> Void
    @State private var isHovering = false

    private var displayTitle: String {
        let text = transcription.enhancedText ?? transcription.text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Chat session") : trimmed
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                EdgeHistoryAvatar(emoji: transcription.modeEmoji)
                Text(displayTitle)
                    .font(.app(size: 17))
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
                    RadialGradient(colors: [Color.white.opacity(0.55), .clear], center: .init(x: 0.3, y: 0.28), startRadius: 0, endRadius: 16)
                        .clipShape(Circle())
                )
                .overlay(Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))

            if let emoji, !emoji.isEmpty, emoji.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation }) {
                Text(emoji).font(.system(size: 15))
            }
        }
        .frame(width: 34, height: 34)
    }
}
