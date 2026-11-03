import CoreGraphics
import Foundation
import Testing

@testable import VoxOS

/// The window switcher: which windows it lists, how the pick moves, the search, and finding a
/// window's Accessibility element.
@Suite
struct WindowSwitcherTests {
    private func entry(
        id: Int, pid: Int32, frame: CGRect, layer: Int = 0, title: String = "", alpha: Double = 1
    ) -> [String: Any] {
        [
            kCGWindowNumber as String: NSNumber(value: id), kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowLayer as String: layer, kCGWindowName as String: title,
            kCGWindowAlpha as String: NSNumber(value: alpha),
            kCGWindowBounds as String: frame.dictionaryRepresentation,
        ]
    }

    @Test func onlyRegularAppsNormalWindowsAreListed() {
        let apps: [pid_t: (name: String, bundleID: String?)] = [10: ("Safari", "com.apple.Safari"), 11: ("Mail", nil)]
        let big = CGRect(x: 0, y: 0, width: 800, height: 600)
        let info = [
            entry(id: 1, pid: 10, frame: big, title: "Docs"),
            entry(id: 2, pid: 10, frame: big, layer: 25),
            entry(id: 3, pid: 99, frame: big),
            entry(id: 4, pid: 11, frame: CGRect(x: 0, y: 0, width: 40, height: 40)),
            entry(id: 5, pid: 11, frame: big, alpha: 0),
            entry(id: 6, pid: 12, frame: big),
            entry(id: 7, pid: 11, frame: big),
        ]
        let windows = WindowSwitcher.windows(from: info, apps: apps, ownPID: 12)
        #expect(windows.map(\.id) == [1, 7], "front to back, as listed")
        #expect(windows.first?.label == "Docs")
        #expect(windows.last?.label == "Mail", "a window with no title shows its app")
    }

    @Test func thePreviousWindowIsPickedFirst() {
        #expect(WindowSwitcher.firstSelection(count: 4, backwards: false) == 1)
        #expect(WindowSwitcher.firstSelection(count: 4, backwards: true) == 3)
        #expect(WindowSwitcher.firstSelection(count: 1, backwards: false) == 0)
    }

    @Test func thePickWrapsAround() {
        #expect(WindowSwitcher.moved(3, by: 1, count: 4) == 0)
        #expect(WindowSwitcher.moved(0, by: -1, count: 4) == 3)
        #expect(WindowSwitcher.moved(1, by: 5, count: 4) == 2, "a row down in a grid")
        #expect(WindowSwitcher.moved(0, by: 1, count: 0) == 0)
        #expect(WindowSwitcher.columns(for: 3) == 3)
        #expect(WindowSwitcher.columns(for: 12) == WindowSwitcher.maxColumns)
    }

    @Test func searchMatchesLettersInOrder() {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        let windows = [
            WindowSwitcher.Window(id: 1, pid: 1, appName: "Safari", bundleID: nil, title: "GitHub", frame: frame),
            WindowSwitcher.Window(id: 2, pid: 2, appName: "Terminal", bundleID: nil, title: "zsh", frame: frame),
        ]
        #expect(WindowSwitcher.filter(windows, query: "sgh").map(\.id) == [1])
        #expect(WindowSwitcher.filter(windows, query: "TZ").map(\.id) == [2], "any case")
        #expect(WindowSwitcher.filter(windows, query: "").count == 2)
        #expect(WindowSwitcher.filter(windows, query: "xyz").isEmpty)
    }

    @Test func theAccessibilityWindowIsFoundByFrameThenTitle() {
        let frame = CGRect(x: 10, y: 20, width: 300, height: 200)
        let other = CGRect(x: 400, y: 20, width: 300, height: 200)
        #expect(
            WindowSwitcher.bestMatch(frame: frame, title: "B", among: [(other, "B"), (frame, "A"), (frame, "B")]) == 2)
        #expect(
            WindowSwitcher.bestMatch(
                frame: frame, title: "", among: [(other, "B"), (frame.offsetBy(dx: 1, dy: 0), "A")]) == 1)
        #expect(WindowSwitcher.bestMatch(frame: frame, title: "B", among: [(other, "B")]) == 0, "moved since")
        #expect(WindowSwitcher.bestMatch(frame: frame, title: "", among: [(other, "B")]) == nil)
    }

    @Test func theTriggerAndTabOpenIt() {
        let keys = AppSwitcher.Trigger.rightCommand.keys
        let tab: Int64 = 48
        #expect(LetterKeyTap.opensSwitcher(code: tab, flags: LetterKeyTap.rightCommand, control: false, keys: keys))
        #expect(!LetterKeyTap.opensSwitcher(code: tab, flags: LetterKeyTap.leftCommand, control: false, keys: keys))
        #expect(!LetterKeyTap.opensSwitcher(code: tab, flags: LetterKeyTap.rightCommand, control: true, keys: keys))
        #expect(!LetterKeyTap.opensSwitcher(code: 0, flags: LetterKeyTap.rightCommand, control: false, keys: keys))
    }

    @Test func aThumbnailKeepsItsShape() {
        let fit = WindowSwitcher.fitted(CGSize(width: 1600, height: 1000), in: CGSize(width: 400, height: 248))
        #expect(fit == CGSize(width: 397, height: 248))
        #expect(
            WindowSwitcher.fitted(CGSize(width: 100, height: 50), in: CGSize(width: 400, height: 248))
                == CGSize(width: 100, height: 50))
    }
}
