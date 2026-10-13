import AppKit
import Testing

@testable import VoxOS

/// The tab is a window that sits on the menu bar line, so the costly mistakes are a window big
/// enough to swallow clicks meant for the menu bar, and a tab that appears where it should not.
@Suite
@MainActor
struct NotchIdleTabTests {

    @Test func atRestItIsASlimLipTheWidthOfTheNotch() {
        let rest = NotchIdleTab.geometry(hovered: false, notchWidth: 200)
        #expect(rest.width == 200)
        #expect(rest.height < 8, "a lip, not a bar")
    }

    @Test func hoverGrowsDownAndOut() {
        let rest = NotchIdleTab.geometry(hovered: false, notchWidth: 200)
        let hover = NotchIdleTab.geometry(hovered: true, notchWidth: 200)
        #expect(hover.width == 200 + 2 * NotchIdleTab.hoverWiden)
        #expect(hover.height > rest.height)
        #expect(hover.height >= NotchIdleTab.contentHeight + NotchIdleTab.restHeight, "room for the glyph row")
    }

    @Test func theWindowIsNoBiggerThanTheShape() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let rest = NotchIdleTab.geometry(hovered: false, notchWidth: 200)
        let frame = NotchIdleTab.frame(for: rest, notchHeight: 37, screenFrame: screen)
        #expect(frame.width == 200, "wider than the notch would cover menu bar items")
        #expect(frame.height == 37 + rest.height)
        #expect(frame.midX == screen.midX)
        #expect(frame.maxY == screen.maxY, "hangs from the top edge")
    }

    @Test func showsOnlyWhenItAddsSomething() {
        #expect(NotchIdleTab.shouldShow(enabled: true, style: .notch, hasNotch: true, recorderPanelVisible: false))
        #expect(
            !NotchIdleTab.shouldShow(enabled: true, style: .notch, hasNotch: true, recorderPanelVisible: true),
            "never under the recorder panel")
        #expect(!NotchIdleTab.shouldShow(enabled: false, style: .notch, hasNotch: true, recorderPanelVisible: false))
        #expect(
            !NotchIdleTab.shouldShow(enabled: true, style: .mini, hasNotch: true, recorderPanelVisible: false),
            "the bottom recorder has no notch to hang from")
        #expect(
            !NotchIdleTab.shouldShow(enabled: true, style: .notch, hasNotch: false, recorderPanelVisible: false),
            "an external display has no notch")
    }

    @Test func onByDefaultAndRegistered() {
        #expect(UserDefaults.standard.object(forKey: DefaultsKeys.notchIdleTabEnabled) as? Bool == true)
        #expect(NotchIdleTab.shrinkDelay > 0.1 && NotchIdleTab.shrinkDelay < 0.5, "no flicker, no lag")
    }

    @Test func thePanelNeverTakesFocus() {
        let panel = NotchIdleTabPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40))
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(panel.level.rawValue < NSWindow.Level.statusBar.rawValue + 3, "below the recorder panel")
    }
}
