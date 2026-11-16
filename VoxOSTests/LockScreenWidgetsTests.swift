import CoreGraphics
import Foundation
import Testing

@testable import VoxOS

/// Where the lock screen's row of widgets goes.
@Suite
@MainActor
struct LockScreenWidgetsTests {

    @Test func theLockScreenRowSitsCentredUnderTheClock() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let frame = LockScreenWidgets.frame(on: screen, size: LockScreenWidgets.size)
        #expect(frame.midX == CGFloat(756))
        #expect(frame.maxY <= screen.maxY * 0.72)
        #expect(frame.minY > screen.maxY * 0.3)
    }
}
