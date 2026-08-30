import SwiftData
import SwiftUI

/// Compact, grouped-by-day history list shown by hovering the left edge of the screen —
/// mirrors VoiceOS's "click the left edge to see history" panel.
struct EdgeHistorySidebarView: View {
    @Query(sort: \Transcription.timestamp, order: .reverse) private var transcriptions: [Transcription]
    @State private var searchText = ""
    let onSelectTranscription: () -> Void

    private var filteredTranscriptions: [Transcription] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Array(transcriptions.prefix(60))
        }
        let query = searchText.lowercased()
        return transcriptions
            .filter {
                $0.text.lowercased().contains(query) || ($0.enhancedText?.lowercased().contains(query) ?? false)
            }
            .prefix(60)
            .map { $0 }
    }

    private var groupedByDay: [(label: String, items: [Transcription])] {
        let calendar = Calendar.current
        let groups: [Date: [Transcription]] = Dictionary(grouping: filteredTranscriptions) { transcription in
            calendar.startOfDay(for: transcription.timestamp)
        }
        let sortedDays: [Date] = groups.keys.sorted(by: >)
        var result: [(label: String, items: [Transcription])] = []
        for day in sortedDays {
            let items: [Transcription] = (groups[day] ?? []).sorted { $0.timestamp > $1.timestamp }
            result.append((label: dayLabel(for: day), items: items))
        }
        return result
    }

    private func dayLabel(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d"
        return formatter.string(from: day)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Color.white.opacity(0.1))
            list
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.96), Color.black.opacity(0.9)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.5))
            TextField("Search", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.9))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                if groupedByDay.isEmpty {
                    Text("No history yet")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.4))
                        .padding(.top, 24)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(groupedByDay, id: \.label) { group in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.4))
                                .padding(.horizontal, 14)

                            ForEach(group.items) { transcription in
                                EdgeHistoryRow(transcription: transcription, onSelect: onSelectTranscription)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }
}

private struct EdgeHistoryRow: View {
    let transcription: Transcription
    let onSelect: () -> Void

    private var displayTitle: String {
        let text = transcription.enhancedText ?? transcription.text
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Chat session") : trimmed
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.25))
                    Text(transcription.modeEmoji ?? "💬")
                        .font(.system(size: 13))
                }
                .frame(width: 26, height: 26)

                Text(displayTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
