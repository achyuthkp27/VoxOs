import AppKit
import ApplicationServices
import Foundation

/// Keeps Accessibility reads from turning back into this process.
///
/// An AX query that resolves to one of our own windows is served in-process, on the calling
/// thread: SwiftUI then builds the accessibility tree for our views right there, including
/// SwiftData queries that must run on the main thread. From a background task that is a crash
/// (`dispatch_assert_queue_fail` in `_SwiftData_SwiftUI`). With the idle notch tab on screen the
/// pointer is on a VoxOS window every time a recording starts from it, so the check has to come
/// before any hit-test, not after.
enum AgentSelfGuard {
    static let ownPID = ProcessInfo.processInfo.processIdentifier

    private static let regionLock = NSLock()
    private static var visibleRegions: [Int: CGRect] = [:]

    /// Records the part of one of our windows that draws anything, as an offset from the window's
    /// top-left corner (see region(of:inWindow:)), or forgets it when `region` is nil.
    ///
    /// The recorder's windows are far larger than the band or pill they show and transparent
    /// around it. Counting the whole window threw away the pointer's context anywhere near the
    /// recorder; with a region recorded, only the visible part counts as ours.
    static func setVisibleRegion(_ region: CGRect?, ofWindowNumber number: Int) {
        regionLock.lock()
        defer { regionLock.unlock() }
        visibleRegions[number] = region
    }

    /// `rect`, a part of the window at `windowFrame`, both in Cocoa's bottom-left global
    /// coordinates, as an offset from the window's top-left corner. Stored that way it stays
    /// right when the window moves, and it maps straight onto the window's AX frame.
    static func region(of rect: CGRect, inWindow windowFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX - windowFrame.minX, y: windowFrame.maxY - rect.maxY, width: rect.width,
            height: rect.height)
    }

    /// Frames of this process's on-screen windows, in the top-left-origin coordinates AX uses.
    /// A window with a recorded visible region contributes only that region.
    static func ownWindowFrames() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        regionLock.lock()
        let regions = visibleRegions
        regionLock.unlock()
        return frames(in: list, ownerPID: ownPID, regions: regions)
    }

    /// The window-list half of ownWindowFrames, apart so it can be checked without a window server.
    static func frames(in list: [[String: Any]], ownerPID: Int32, regions: [Int: CGRect]) -> [CGRect] {
        list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == ownerPID,
                let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"]
            else { return nil }
            let frame = CGRect(x: x, y: y, width: w, height: h)
            if let number = info[kCGWindowNumber as String] as? Int, let region = regions[number] {
                return region.offsetBy(dx: frame.minX, dy: frame.minY)
            }
            return frame
        }
    }

    static func contains(_ point: CGPoint, in frames: [CGRect]) -> Bool {
        frames.contains { $0.contains(point) }
    }

    /// True when a hit-test at `point` would land on one of our own windows.
    static func pointIsInOwnWindow(_ point: CGPoint) -> Bool {
        contains(point, in: ownWindowFrames())
    }

    /// True when the element belongs to this process. Reading the pid does not query the app.
    static func isOwn(_ element: AXUIElement) -> Bool {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success && pid == ownPID
    }

    /// True while this process is the frontmost app, so the system-wide focused element would be ours.
    static var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPID
    }
}
