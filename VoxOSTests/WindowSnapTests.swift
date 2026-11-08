import CoreGraphics
import Testing

@testable import VoxOS

/// L, R and F in the window switcher: the frame a window is given, and the screen it is given
/// it on. AppKit measures screens from the bottom left, Accessibility from the top left.
@Suite
struct WindowSnapTests {

    /// A 1440×900 main screen with a 25-point menu bar and no Dock: visible from y 0 to 875.
    private let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let mainVisible = CGRect(x: 0, y: 0, width: 1440, height: 875)

    @Test func fillTakesTheWholeVisibleAreaBelowTheMenuBar() {
        let frame = WindowSwitcher.snapFrame(.fill, visible: mainVisible, primaryHeight: 900)
        #expect(frame == CGRect(x: 0, y: 25, width: 1440, height: 875))
    }

    @Test func leftAndRightEachTakeHalf() {
        let left = WindowSwitcher.snapFrame(.left, visible: mainVisible, primaryHeight: 900)
        let right = WindowSwitcher.snapFrame(.right, visible: mainVisible, primaryHeight: 900)
        #expect(left == CGRect(x: 0, y: 25, width: 720, height: 875))
        #expect(right == CGRect(x: 720, y: 25, width: 720, height: 875))
    }

    @Test func anOddWidthLeavesNoOverlap() {
        let visible = CGRect(x: 0, y: 0, width: 1441, height: 875)
        let left = WindowSwitcher.snapFrame(.left, visible: visible, primaryHeight: 900)
        let right = WindowSwitcher.snapFrame(.right, visible: visible, primaryHeight: 900)
        #expect(left.maxX <= right.minX)
        #expect(right.maxX == 1441)
    }

    @Test func aScreenAboveTheMainOneIsMeasuredFromTheMainOnesTop() {
        // A 1920×1080 display placed above the main screen, with a menu bar on it too.
        let upperVisible = CGRect(x: 0, y: 900, width: 1920, height: 1055)
        let frame = WindowSwitcher.snapFrame(.fill, visible: upperVisible, primaryHeight: 900)
        #expect(frame == CGRect(x: 0, y: -1055, width: 1920, height: 1055))
    }

    @Test func aWindowSnapsOnTheScreenHoldingItsCenter() {
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let rightVisible = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        let screens = [(frame: main, visible: mainVisible), (frame: right, visible: rightVisible)]
        // Mostly on the right-hand display, in top-left coordinates.
        let window = CGRect(x: 1300, y: 100, width: 800, height: 600)
        #expect(WindowSwitcher.screenVisibleFrame(for: window, screens: screens, primaryHeight: 900) == rightVisible)
    }

    @Test func aWindowOffEveryScreenHasNoScreen() {
        let screens = [(frame: main, visible: mainVisible)]
        let window = CGRect(x: 5000, y: 5000, width: 100, height: 100)
        #expect(WindowSwitcher.screenVisibleFrame(for: window, screens: screens, primaryHeight: 900) == nil)
    }
}
