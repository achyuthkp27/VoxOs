import CoreGraphics
import Foundation
import Testing

@testable import VoxOS

@Suite
struct FocusBlurTests {
    private typealias Window = FocusBlur.WindowInfo

    private static let left = CGDirectDisplayID(1)
    private static let right = CGDirectDisplayID(2)
    private static let displays: [CGDirectDisplayID: CGRect] = [
        left: CGRect(x: 0, y: 0, width: 1000, height: 800),
        right: CGRect(x: 1000, y: 0, width: 1000, height: 800),
    ]

    private static func window(_ id: CGWindowID, pid: pid_t, x: CGFloat = 100) -> Window {
        Window(id: id, pid: pid, bounds: CGRect(x: x, y: 100, width: 400, height: 300))
    }

    private static func place(
        _ windows: [Window], front: pid_t?, ignored: Bool = false, appWide: Bool = false,
        others: FocusBlur.OtherDisplays = .blur
    ) -> FocusBlur.Placement {
        FocusBlur.placement(
            windows: windows, frontPID: front, frontIgnored: ignored, displays: displays, appWide: appWide,
            otherDisplays: others)
    }

    @Test func theSheetGoesBelowTheFrontAppsFrontWindow() {
        let windows = [Self.window(10, pid: 1), Self.window(11, pid: 1), Self.window(20, pid: 2)]
        let placement = Self.place(windows, front: 1)
        #expect(placement[Self.left] == .some(10))
        #expect(placement[Self.right] == .some(10))
    }

    @Test func theFrontAppsWindowIsFoundBelowAFloatingOneOfAnotherApp() {
        // A window of another app can sit above for a moment (an app opening): the sheet still
        // goes below the front app's window.
        let windows = [Self.window(30, pid: 3), Self.window(10, pid: 1)]
        #expect(Self.place(windows, front: 1)[Self.left] == .some(10))
    }

    @Test func appWideKeepsTheRunOfTheAppsWindowsSharp() {
        let windows = [
            Self.window(10, pid: 1), Self.window(11, pid: 1), Self.window(20, pid: 2), Self.window(12, pid: 1),
        ]
        // Stops at the first window of another app: 12 is behind 20, so it is blurred.
        #expect(Self.place(windows, front: 1, appWide: true)[Self.left] == .some(11))
    }

    @Test func nothingIsBlurredWhileAnIgnoredAppIsInFront() {
        let placement = Self.place([Self.window(10, pid: 1)], front: 1, ignored: true)
        #expect(placement[Self.left] == .some(nil))
        #expect(placement[Self.right] == .some(nil))
    }

    @Test func nothingIsBlurredWhenTheFrontAppHasNoWindow() {
        let placement = Self.place([Self.window(20, pid: 2)], front: 1)
        #expect(placement.values.allSatisfy { $0 == nil })
        #expect(Self.place([], front: nil).values.allSatisfy { $0 == nil })
    }

    @Test func anotherDisplayCanKeepItsOwnFrontWindowSharp() {
        let windows = [Self.window(10, pid: 1), Self.window(20, pid: 2, x: 1200), Self.window(21, pid: 2, x: 1300)]
        let placement = Self.place(windows, front: 1, others: .keepTopWindow)
        #expect(placement[Self.left] == .some(10))
        #expect(placement[Self.right] == .some(20))
        // Blurring everything, the other display's windows go under the sheet too.
        #expect(Self.place(windows, front: 1)[Self.right] == .some(10))
    }

    @Test func aWindowBelongsToTheDisplayHoldingMostOfIt() {
        let straddling = CGRect(x: 900, y: 100, width: 400, height: 300)
        #expect(FocusBlur.display(of: straddling, in: Self.displays) == Self.right)
        #expect(FocusBlur.display(of: CGRect(x: 5000, y: 0, width: 10, height: 10), in: Self.displays) == nil)
    }

    @Test func aShakeIsFourQuickReversals() {
        var state = ShakeState()
        var fired = false
        var time = 0.0
        for stroke in 0..<6 {
            let dx: CGFloat = stroke.isMultiple(of: 2) ? 80 : -80
            time += 0.1
            fired = state.add(dx: dx, at: time) || fired
        }
        #expect(fired)
    }

    @Test func slowOrSmallMovementsAreNotAShake() {
        var small = ShakeState()
        var time = 0.0
        var fired = false
        for stroke in 0..<10 {
            time += 0.05
            fired = small.add(dx: stroke.isMultiple(of: 2) ? 10 : -10, at: time) || fired
        }
        #expect(!fired)

        var slow = ShakeState()
        time = 0
        for stroke in 0..<10 {
            time += 0.5
            fired = slow.add(dx: stroke.isMultiple(of: 2) ? 100 : -100, at: time) || fired
        }
        #expect(!fired)
    }

    @Test func settingsAreReadFromTheirKeys() {
        let suite = "FocusBlurTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: DefaultsKeys.focusBlurEnabled)
        defaults.set("dark", forKey: DefaultsKeys.focusBlurTint)
        defaults.set("keepTopWindow", forKey: DefaultsKeys.focusBlurOtherDisplays)
        defaults.set(["us.zoom.xos"], forKey: DefaultsKeys.focusBlurIgnoredApps)
        let settings = FocusBlur.Settings.read(from: defaults)
        #expect(settings.enabled)
        #expect(settings.tint == .dark)
        #expect(settings.otherDisplays == .keepTopWindow)
        #expect(settings.ignoredApps == ["us.zoom.xos"])
    }
}
