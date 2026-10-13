import Foundation
import Testing

@testable import VoxOS

struct HistoryPageCursorTests {

    private func transcription(at timestamp: Date) -> Transcription {
        let transcription = Transcription(text: "t", duration: 1)
        transcription.timestamp = timestamp
        return transcription
    }

    @Test func emptyPageHasNoCursor() {
        #expect(HistoryPageCursor(after: [], previous: nil) == nil)
    }

    @Test func cursorKeepsEveryLoadedRowAtTheBoundaryTimestamp() {
        let boundary = Date(timeIntervalSinceReferenceDate: 1_000)
        let newer = transcription(at: boundary.addingTimeInterval(10))
        let tieA = transcription(at: boundary)
        let tieB = transcription(at: boundary)

        let cursor = HistoryPageCursor(after: [newer, tieA, tieB], previous: nil)

        #expect(cursor?.timestamp == boundary)
        #expect(cursor?.loadedIDsAtTimestamp == [tieA.id, tieB.id])
    }

    @Test func pageEntirelyAtTheBoundaryCarriesEarlierIDs() {
        let boundary = Date(timeIntervalSinceReferenceDate: 1_000)
        let first = transcription(at: boundary)
        let second = transcription(at: boundary)
        let previous = HistoryPageCursor(timestamp: boundary, loadedIDsAtTimestamp: [first.id])

        let cursor = HistoryPageCursor(after: [second], previous: previous)

        #expect(cursor?.loadedIDsAtTimestamp == [first.id, second.id])
    }

    @Test func olderBoundaryStartsAFreshIDList() {
        let previous = HistoryPageCursor(
            timestamp: Date(timeIntervalSinceReferenceDate: 2_000), loadedIDsAtTimestamp: [UUID()])
        let older = transcription(at: Date(timeIntervalSinceReferenceDate: 1_000))

        let cursor = HistoryPageCursor(after: [older], previous: previous)

        #expect(cursor?.loadedIDsAtTimestamp == [older.id])
    }
}

struct DashboardProductivityAxisTests {

    @Test func smallBoundsAreMultiplesOfFour() {
        #expect(DashboardProductivityChartData.yAxisUpperBound(for: 0) == 0)
        #expect(DashboardProductivityChartData.yAxisUpperBound(for: 1) == 4)
        #expect(DashboardProductivityChartData.yAxisUpperBound(for: 2) == 4)
        #expect(DashboardProductivityChartData.yAxisUpperBound(for: 5) == 8)
        #expect(DashboardProductivityChartData.yAxisUpperBound(for: 6) == 8)
        #expect(DashboardProductivityChartData.yAxisUpperBound(for: 37) == 40)
    }

    @Test func largeBoundsAreUnchanged() {
        #expect(DashboardProductivityChartData.yAxisUpperBound(for: 1_000) == 1_100)
    }

    @Test func boundsBelowFortyHaveWholeQuarters() {
        for value in 1..<40 {
            let bound = DashboardProductivityChartData.yAxisUpperBound(for: value)
            #expect(bound >= value)
            #expect(bound >= 40 || bound % 4 == 0, "bound \(bound) for \(value)")
        }
    }
}
