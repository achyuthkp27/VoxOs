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

    /// Frames of this process's on-screen windows, in the top-left-origin coordinates AX uses.
    static func ownWindowFrames() -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? Int32) == ownPID,
                let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"]
            else { return nil }
            return CGRect(x: x, y: y, width: w, height: h)
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
