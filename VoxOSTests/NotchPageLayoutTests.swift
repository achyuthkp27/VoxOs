import Foundation
import Testing

@testable import VoxOS

/// Notch Home's page order and switches: the notch walks the user's order, skips pages turned
/// off, and still falls back to a page that exists.
@Suite
struct NotchPageLayoutTests {
    private final class Defaults {
        let suiteName = "NotchPageLayoutTests.\(UUID().uuidString)"
        let defaults: UserDefaults

        init() {
            defaults = UserDefaults(suiteName: suiteName)!
        }

        deinit {
            defaults.removePersistentDomain(forName: suiteName)
        }
    }

    @Test func withoutASavedOrderEveryPageIsOn() {
        let box = Defaults()
        #expect(NotchPageLayout.ordered(from: box.defaults) == NotchHomePage.allCases)
        #expect(NotchPageLayout.disabled(from: box.defaults).isEmpty)
    }

    @Test func aSavedOrderIsWalkedAsSaved() {
        let box = Defaults()
        NotchPageLayout.save(order: [.shelf, .timer, .today], disabled: [], to: box.defaults)

        #expect(NotchPageLayout.ordered(from: box.defaults).prefix(3) == [.shelf, .timer, .today])
        #expect(
            NotchHomePage.available(hasTrack: false, defaults: box.defaults)
                == [.shelf, .timer, .today, .weather, .sound])
    }

    @Test func aPageAddedLaterIsAppendedRatherThanDropped() {
        let box = Defaults()
        // An order saved before `sound` existed.
        box.defaults.set(["shelf", "today"], forKey: DefaultsKeys.notchPageOrder)

        let ordered = NotchPageLayout.ordered(from: box.defaults)

        #expect(ordered.prefix(2) == [.shelf, .today])
        #expect(Set(ordered.dropFirst(2)) == [.music, .weather, .timer, .sound])
        #expect(ordered.count == NotchHomePage.allCases.count)
    }

    @Test func unknownAndRepeatedValuesAreIgnored() {
        let box = Defaults()
        box.defaults.set(["weather", "gone", "weather", "today"], forKey: DefaultsKeys.notchPageOrder)

        let ordered = NotchPageLayout.ordered(from: box.defaults)

        #expect(ordered.prefix(2) == [.weather, .today])
        #expect(ordered.count == NotchHomePage.allCases.count)
        #expect(ordered.filter { $0 == .weather }.count == 1)
    }

    @Test func aPageTurnedOffNeverShowsAndMusicStillNeedsATrack() {
        let box = Defaults()
        NotchPageLayout.save(order: NotchHomePage.allCases, disabled: [.weather, .shelf], to: box.defaults)

        let withoutTrack = NotchHomePage.available(hasTrack: false, defaults: box.defaults)
        let withTrack = NotchHomePage.available(hasTrack: true, defaults: box.defaults)

        #expect(withoutTrack == [.today, .timer, .sound])
        #expect(withTrack == [.music, .today, .timer, .sound])
        #expect(!withoutTrack.contains(.music))
        #expect(!withTrack.contains(.weather))
        #expect(!withTrack.contains(.shelf))
    }

    @Test func openingPrefersTheLivelyPageOnlyWhileItIsOn() {
        let box = Defaults()
        NotchPageLayout.save(order: NotchHomePage.allCases, disabled: [.timer], to: box.defaults)

        #expect(
            NotchHomePage.preferred(
                hasTrack: true, timerRunning: true, dropping: false, defaults: box.defaults) == .music)
        #expect(
            NotchHomePage.preferred(
                hasTrack: false, timerRunning: true, dropping: false, defaults: box.defaults) == .today)
        #expect(
            NotchHomePage.preferred(
                hasTrack: false, timerRunning: false, dropping: true, defaults: box.defaults) == .shelf)
    }

    @Test func openingFallsBackToTheFirstPageThatIsOn() {
        let box = Defaults()
        NotchPageLayout.save(
            order: [.shelf, .weather, .today, .music, .timer, .sound], disabled: [.today], to: box.defaults)

        // The meeting would open the day, which is off; the shelf comes first in the saved order.
        #expect(
            NotchHomePage.preferred(
                hasTrack: false, timerRunning: false, dropping: false, meeting: true, defaults: box.defaults) == .shelf)
    }

    @Test func turningEveryPageOffStillLeavesTheNotchSomethingToShow() {
        let box = Defaults()
        NotchPageLayout.save(order: NotchHomePage.allCases, disabled: Set(NotchHomePage.allCases), to: box.defaults)

        #expect(NotchHomePage.available(hasTrack: false, defaults: box.defaults) == [.today])
        #expect(
            NotchHomePage.preferred(
                hasTrack: false, timerRunning: false, dropping: false, defaults: box.defaults) == .today)
    }

    @Test func arrowsMoveAPageOnePlaceAndStopAtTheEnds() {
        let order: [NotchHomePage] = [.music, .today, .weather, .timer]

        #expect(NotchPageLayout.moving(.weather, by: -1, in: order) == [.music, .weather, .today, .timer])
        #expect(NotchPageLayout.moving(.weather, by: 1, in: order) == [.music, .today, .timer, .weather])
        #expect(NotchPageLayout.moving(.music, by: -1, in: order) == order)
        #expect(NotchPageLayout.moving(.timer, by: 1, in: order) == order)
    }

    @Test func aDroppedPageLandsWhereThePointerLeftIt() {
        let order: [NotchHomePage] = [.music, .today, .weather, .timer]

        // Dragged up: it takes the target's place, above it.
        #expect(NotchPageLayout.moving(.timer, onto: .today, in: order) == [.music, .timer, .today, .weather])
        // Dragged down: it takes the target's place, below it.
        #expect(NotchPageLayout.moving(.music, onto: .weather, in: order) == [.today, .weather, .music, .timer])
        // Dropped on itself: nothing moves.
        #expect(NotchPageLayout.moving(.today, onto: .today, in: order) == order)
    }

    @Test func resetRestoresTheDefaultOrderAndEveryPage() {
        let box = Defaults()
        NotchPageLayout.save(order: [.sound, .shelf], disabled: [.today], to: box.defaults)

        NotchPageLayout.reset(in: box.defaults)

        #expect(NotchPageLayout.ordered(from: box.defaults) == NotchHomePage.allCases)
        #expect(NotchPageLayout.disabled(from: box.defaults).isEmpty)
    }
}
