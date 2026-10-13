import AppKit
import Testing

@testable import VoxOS

/// The notch metrics are baked into the hosted view when the window is built, so a window that
/// is shown on a different screen than it was built for has to be rebuilt first.
@MainActor
struct NotchWindowRebuildTests {

    private let builtIn: NotchRecorderPanel.WindowMetrics = (
        frame: NSRect(x: 600, y: 900, width: 300, height: 120), notchWidth: 200, notchHeight: 32
    )

    @Test func sameMetricsKeepTheWindow() {
        #expect(!NotchWindowManager.needsRebuild(built: builtIn, current: builtIn))
    }

    @Test func aDifferentScreenRebuilds() {
        let external: NotchRecorderPanel.WindowMetrics = (
            frame: NSRect(x: 2000, y: 1400, width: 280, height: 110), notchWidth: 180, notchHeight: 24
        )
        #expect(NotchWindowManager.needsRebuild(built: builtIn, current: external))

        var samePlaceOtherNotch = builtIn
        samePlaceOtherNotch.notchHeight = 24
        #expect(NotchWindowManager.needsRebuild(built: builtIn, current: samePlaceOtherNotch))
    }

    @Test func missingMetricsNeverForceARebuild() {
        // No window yet, or no screen at all: `show()` handles both without rebuilding.
        #expect(!NotchWindowManager.needsRebuild(built: nil, current: builtIn))
        #expect(!NotchWindowManager.needsRebuild(built: builtIn, current: nil))
    }
}
