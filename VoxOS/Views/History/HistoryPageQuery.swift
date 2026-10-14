import Foundation
import SwiftData

/// Where the next history page starts. Pages are sorted newest first by timestamp, and several
/// transcriptions can share one timestamp, so the cursor also keeps the ids already loaded at
/// that timestamp. A plain `timestamp < last` cursor skipped the rest of them when a page
/// boundary fell inside such a run.
struct HistoryPageCursor: Equatable {
    let timestamp: Date
    let loadedIDsAtTimestamp: [UUID]

    init(timestamp: Date, loadedIDsAtTimestamp: [UUID]) {
        self.timestamp = timestamp
        self.loadedIDsAtTimestamp = loadedIDsAtTimestamp
    }

    /// The cursor after `page` was fetched from `previous`, or nil for an empty page. When the
    /// whole page shares the previous cursor's timestamp, the ids loaded earlier are kept too.
    init?(after page: [Transcription], previous: HistoryPageCursor?) {
        guard let last = page.last else { return nil }
        let timestamp = last.timestamp
        let carried = previous?.timestamp == timestamp ? previous?.loadedIDsAtTimestamp ?? [] : []
        self.timestamp = timestamp
        self.loadedIDsAtTimestamp = carried + page.filter { $0.timestamp == timestamp }.map(\.id)
    }
}

enum HistoryPageQuery {
    /// One page of history, newest first, optionally filtered by `searchText` and by the mode
    /// that produced it (`modeName`, nil for every mode), and starting after `cursor`.
    static func descriptor(
        searchText: String,
        modeName: String? = nil,
        after cursor: HistoryPageCursor?,
        pageSize: Int
    ) -> FetchDescriptor<Transcription> {
        var descriptor = FetchDescriptor<Transcription>(
            sortBy: [SortDescriptor(\Transcription.timestamp, order: .reverse)]
        )
        let query = searchText

        if let modeName {
            descriptor.predicate = modePredicate(query: query, modeName: modeName, after: cursor)
        } else if let cursor {
            let timestamp = cursor.timestamp
            let loadedIDs = cursor.loadedIDsAtTimestamp
            if !query.isEmpty {
                descriptor.predicate = #Predicate<Transcription> { transcription in
                    (transcription.text.localizedStandardContains(query)
                        || (transcription.enhancedText?.localizedStandardContains(query) ?? false))
                        && (transcription.timestamp < timestamp
                            || (transcription.timestamp == timestamp && !loadedIDs.contains(transcription.id)))
                }
            } else {
                descriptor.predicate = #Predicate<Transcription> { transcription in
                    transcription.timestamp < timestamp
                        || (transcription.timestamp == timestamp && !loadedIDs.contains(transcription.id))
                }
            }
        } else if !query.isEmpty {
            descriptor.predicate = #Predicate<Transcription> { transcription in
                transcription.text.localizedStandardContains(query)
                    || (transcription.enhancedText?.localizedStandardContains(query) ?? false)
            }
        }

        descriptor.fetchLimit = pageSize
        return descriptor
    }

    /// Every transcription matching `searchText` (and `modeName` when set), or all of them when
    /// both are empty. Used by Select All, so it must match the query the list is showing.
    static func allMatchingDescriptor(searchText: String, modeName: String? = nil) -> FetchDescriptor<Transcription> {
        var descriptor = FetchDescriptor<Transcription>()
        let query = searchText
        if let modeName {
            descriptor.predicate = modePredicate(query: query, modeName: modeName, after: nil)
        } else if !query.isEmpty {
            descriptor.predicate = #Predicate<Transcription> { transcription in
                transcription.text.localizedStandardContains(query)
                    || (transcription.enhancedText?.localizedStandardContains(query) ?? false)
            }
        }
        descriptor.propertiesToFetch = [\.id]
        return descriptor
    }

    /// The same filters as above, limited to transcriptions made in `modeName`. Kept apart so
    /// the unfiltered predicates, which every History view uses, stay exactly as they were.
    private static func modePredicate(
        query: String,
        modeName: String,
        after cursor: HistoryPageCursor?
    ) -> Predicate<Transcription> {
        let mode: String? = modeName
        if let cursor {
            let timestamp = cursor.timestamp
            let loadedIDs = cursor.loadedIDsAtTimestamp
            if !query.isEmpty {
                return #Predicate<Transcription> { transcription in
                    transcription.modeName == mode
                        && (transcription.text.localizedStandardContains(query)
                            || (transcription.enhancedText?.localizedStandardContains(query) ?? false))
                        && (transcription.timestamp < timestamp
                            || (transcription.timestamp == timestamp && !loadedIDs.contains(transcription.id)))
                }
            }
            return #Predicate<Transcription> { transcription in
                transcription.modeName == mode
                    && (transcription.timestamp < timestamp
                        || (transcription.timestamp == timestamp && !loadedIDs.contains(transcription.id)))
            }
        }
        if !query.isEmpty {
            return #Predicate<Transcription> { transcription in
                transcription.modeName == mode
                    && (transcription.text.localizedStandardContains(query)
                        || (transcription.enhancedText?.localizedStandardContains(query) ?? false))
            }
        }
        return #Predicate<Transcription> { transcription in
            transcription.modeName == mode
        }
    }
}
