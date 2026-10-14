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

/// The date range the History page shows, chosen in its toolbar.
enum HistoryDateRange: String, CaseIterable, Identifiable {
    case today
    case week
    case month
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return String(localized: "Today")
        case .week: return String(localized: "7 days")
        case .month: return String(localized: "30 days")
        case .all: return String(localized: "All time")
        }
    }

    /// The earliest timestamp in range, counted in whole days back from `now`'s day ("7 days" is
    /// today and the six days before it), or nil for all time.
    func startDate(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .today: return today
        case .week: return calendar.date(byAdding: .day, value: -6, to: today)
        case .month: return calendar.date(byAdding: .day, value: -29, to: today)
        case .all: return nil
        }
    }
}

enum HistoryPageQuery {
    /// One page of history, newest first, optionally filtered by `searchText`, by the mode that
    /// produced it (`modeName`, nil for every mode) and to transcriptions made at or after
    /// `since` (nil for all time), and starting after `cursor`.
    static func descriptor(
        searchText: String,
        modeName: String? = nil,
        since: Date? = nil,
        after cursor: HistoryPageCursor?,
        pageSize: Int
    ) -> FetchDescriptor<Transcription> {
        var descriptor = FetchDescriptor<Transcription>(
            sortBy: [SortDescriptor(\Transcription.timestamp, order: .reverse)]
        )
        let query = searchText

        if modeName != nil || since != nil {
            descriptor.predicate = filteredPredicate(query: query, modeName: modeName, since: since, after: cursor)
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

    /// Every transcription matching `searchText` (and `modeName` and `since` when set), or all of
    /// them when no filter is set. Used by Select All, so it must match the query the list is showing.
    static func allMatchingDescriptor(
        searchText: String,
        modeName: String? = nil,
        since: Date? = nil
    ) -> FetchDescriptor<Transcription> {
        var descriptor = FetchDescriptor<Transcription>()
        let query = searchText
        if modeName != nil || since != nil {
            descriptor.predicate = filteredPredicate(query: query, modeName: modeName, since: since, after: nil)
        } else if !query.isEmpty {
            descriptor.predicate = #Predicate<Transcription> { transcription in
                transcription.text.localizedStandardContains(query)
                    || (transcription.enhancedText?.localizedStandardContains(query) ?? false)
            }
        }
        descriptor.propertiesToFetch = [\.id]
        return descriptor
    }

    /// The same filters as above, limited to transcriptions made in `modeName` (when set) and at
    /// or after `since` (when set). Kept apart so the unfiltered predicates, which every History
    /// view uses, stay exactly as they were. A missing cursor or start date becomes a bound no
    /// row falls outside, so only the mode and search text still need separate predicates.
    private static func filteredPredicate(
        query: String,
        modeName: String?,
        since: Date?,
        after cursor: HistoryPageCursor?
    ) -> Predicate<Transcription> {
        let start = since ?? .distantPast
        let timestamp = cursor?.timestamp ?? .distantFuture
        let loadedIDs = cursor?.loadedIDsAtTimestamp ?? []

        if let modeName {
            let mode: String? = modeName
            if !query.isEmpty {
                return #Predicate<Transcription> { transcription in
                    transcription.modeName == mode
                        && transcription.timestamp >= start
                        && (transcription.text.localizedStandardContains(query)
                            || (transcription.enhancedText?.localizedStandardContains(query) ?? false))
                        && (transcription.timestamp < timestamp
                            || (transcription.timestamp == timestamp && !loadedIDs.contains(transcription.id)))
                }
            }
            return #Predicate<Transcription> { transcription in
                transcription.modeName == mode
                    && transcription.timestamp >= start
                    && (transcription.timestamp < timestamp
                        || (transcription.timestamp == timestamp && !loadedIDs.contains(transcription.id)))
            }
        }
        if !query.isEmpty {
            return #Predicate<Transcription> { transcription in
                transcription.timestamp >= start
                    && (transcription.text.localizedStandardContains(query)
                        || (transcription.enhancedText?.localizedStandardContains(query) ?? false))
                    && (transcription.timestamp < timestamp
                        || (transcription.timestamp == timestamp && !loadedIDs.contains(transcription.id)))
            }
        }
        return #Predicate<Transcription> { transcription in
            transcription.timestamp >= start
                && (transcription.timestamp < timestamp
                    || (transcription.timestamp == timestamp && !loadedIDs.contains(transcription.id)))
        }
    }
}
