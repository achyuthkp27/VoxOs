import Foundation
import SwiftData

/// What was dictated and asked today, from the local history, for the model to sum up.
/// Composition is pure so the capping can be tested; the fetch is the only SwiftData touch.
enum AgentDaySummary {
    static let maxEntries = 60
    static let maxCharsPerEntry = 240
    static let maxTotalChars = 6_000

    struct Entry {
        let time: Date
        let text: String
        let promptName: String?
    }

    static func compose(_ entries: [Entry], now: Date = Date()) -> [String: Any] {
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"

        var lines: [String] = []
        var total = 0
        var truncated = entries.count > maxEntries
        for entry in entries.sorted(by: { $0.time < $1.time }).prefix(maxEntries) {
            let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let clipped = text.count > maxCharsPerEntry ? String(text.prefix(maxCharsPerEntry)) + "…" : text
            let label = entry.promptName.map { " [\($0)]" } ?? ""
            let line = "\(timeFormatter.string(from: entry.time))\(label): \(clipped)"
            if total + line.count > maxTotalChars {
                truncated = true
                break
            }
            lines.append(line)
            total += line.count
        }
        return [
            "date": dayFormatter.string(from: now),
            "count": entries.count,
            "entries": lines,
            "truncated": truncated,
            "hint": lines.isEmpty
                ? "Nothing was dictated or asked today."
                : "Sum these up in a few sentences: what was worked on, what the agent was asked, anything left open.",
        ]
    }

    @MainActor
    static func today() -> [String: Any] {
        guard let context = AgentEnvironment.engine?.modelContext else { return ["error": "history is not available"] }
        let start = Calendar.current.startOfDay(for: Date())
        let descriptor = FetchDescriptor<Transcription>(
            predicate: #Predicate { $0.timestamp >= start }, sortBy: [SortDescriptor(\.timestamp)])
        let items = (try? context.fetch(descriptor)) ?? []
        return compose(
            items.map { Entry(time: $0.timestamp, text: $0.enhancedText ?? $0.text, promptName: $0.promptName) })
    }
}
