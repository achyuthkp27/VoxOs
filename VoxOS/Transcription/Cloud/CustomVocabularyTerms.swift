import Foundation
import SwiftData

/// Custom-dictionary terms handed to cloud and streaming providers.
///
/// The `ModelContext` these services receive is the container's `mainContext`, which SwiftData
/// only allows on the main actor. The providers themselves are plain classes whose `connect` /
/// `transcribe` run on whatever executor awaited them, so the fetch is isolated here and callers
/// `await` it; only value types cross back.
enum CustomVocabularyTerms {
    @MainActor
    static func fetch(from modelContext: ModelContext, limit: Int? = nil) -> [String] {
        let descriptor = FetchDescriptor<VocabularyWord>(sortBy: [SortDescriptor(\.word)])
        guard let vocabularyWords = try? modelContext.fetch(descriptor) else {
            return []
        }
        var seen = Set<String>()
        var unique: [String] = []
        for word in vocabularyWords {
            let trimmed = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            unique.append(trimmed)
            if let limit, unique.count == limit { break }
        }
        return unique
    }
}
