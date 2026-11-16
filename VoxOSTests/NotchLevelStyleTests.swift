import Foundation
import Testing

@testable import VoxOS

/// The styles the volume and brightness level can be drawn in.
@Suite
@MainActor
struct NotchLevelStyleTests {

    @Test func everyLevelStyleHasATitleAndBarIsTheDefault() {
        #expect(NotchHUD.Style.allCases.allSatisfy { !$0.title.isEmpty })
        #expect(NotchHUD.Style(rawValue: "bar") == .bar)
        #expect(NotchHUD.Style(rawValue: "gone") == nil)
    }
}
