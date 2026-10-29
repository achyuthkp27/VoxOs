import AppKit
import ApplicationServices
import CoreGraphics

/// How wide a band beside the notch can be before it covers something in the menu bar.
///
/// Left of the notch are the front app's menus; right of it, status items. On current macOS the
/// status items are drawn into the menu bar itself rather than as windows of their own (measured
/// on macOS 26: the window list shows only the menu bar), so both sides are read through
/// Accessibility, which VoxOS already has for the Agent. Without it nothing is measured and a
/// band is drawn as before.
///
/// Every Accessibility call waits on the app it asks, so measuring runs off the main thread with
/// a short timeout per app, and the result is cached by the caller.
enum NotchMenuBarClearance {
    /// Kept between a band and the nearest item, so they never touch.
    static let margin: CGFloat = 6
    /// Per app: a hung app costs this much, not the default six seconds.
    static let messagingTimeout: Float = 0.15

    /// The widest wing that fits on both sides; nil when nothing could be measured.
    /// Coordinates are global, top-left origin, like Accessibility's.
    static func allowedWing(notchMinX: CGFloat, notchMaxX: CGFloat, menusMaxX: CGFloat?, statusItemsMinX: CGFloat?)
        -> CGFloat?
    {
        let left = menusMaxX.map { notchMinX - $0 }
        let right = statusItemsMinX.map { $0 - notchMaxX }
        let free = [left, right].compactMap { $0 }
        guard let narrowest = free.min() else { return nil }
        return max(0, narrowest - margin)
    }

    struct Measurement: Equatable {
        let wing: CGFloat?
        /// What set the limit, for the log: "menus 500" or "status 888 (pid 123)".
        let limitedBy: String
    }

    /// Measures both sides off the main thread; `front` is the app whose menus are showing. Status
    /// items can belong to any running app that is not barred from the menu bar (VoxOS's own
    /// excluded: the band may sit over its own icon). Each app's activation policy is a round trip
    /// to Launch Services, which can take seconds while it is busy (an install, `lsregister`), so
    /// the list is read here too, never on the main thread (measured on macOS 26).
    static func measure(notchMinX: CGFloat, notchMaxX: CGFloat, front: pid_t?) async -> Measurement {
        await Task.detached(priority: .utility) {
            guard AXIsProcessTrusted() else { return Measurement(wing: nil, limitedBy: "no Accessibility") }
            let menus = front.flatMap { menusMaxX(of: $0, before: notchMinX) }
            let own = ProcessInfo.processInfo.processIdentifier
            let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy != .prohibited }
                .map(\.processIdentifier)
            let status = apps.filter { $0 != own }
                .compactMap { pid in statusItemsMinX(of: pid, after: notchMaxX).map { (pid, $0) } }
                .min { $0.1 < $1.1 }
            let wing = allowedWing(
                notchMinX: notchMinX, notchMaxX: notchMaxX, menusMaxX: menus, statusItemsMinX: status?.1)
            let left = menus.map { notchMinX - $0 } ?? .infinity
            let right = status.map { $0.1 - notchMaxX } ?? .infinity
            let limitedBy =
                left <= right
                ? "menus to \(Int(menus ?? 0))" : "status item at \(Int(status?.1 ?? 0)) (pid \(status?.0 ?? 0))"
            return Measurement(wing: wing, limitedBy: limitedBy)
        }.value
    }

    /// The right edge of the app's last menu left of the notch.
    private static func menusMaxX(of pid: pid_t, before notchMinX: CGFloat) -> CGFloat? {
        itemFrames(of: pid, in: kAXMenuBarAttribute)
            .map(\.maxX)
            .filter { $0 <= notchMinX + 1 }
            .max()
    }

    /// The left edge of the app's nearest status item right of the notch.
    private static func statusItemsMinX(of pid: pid_t, after notchMaxX: CGFloat) -> CGFloat? {
        itemFrames(of: pid, in: kAXExtrasMenuBarAttribute)
            // A real icon is at least a few points wide; spacers and hidden items are not.
            .filter { $0.minY < 4 && $0.height < 60 && $0.width >= 8 }
            .map(\.minX)
            .filter { $0 >= notchMaxX - 1 }
            .min()
    }

    private static func itemFrames(of pid: pid_t, in bar: String) -> [CGRect] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let menuBar = element(app, bar), let items = attribute(menuBar, kAXChildrenAttribute) as? [AXUIElement]
        else { return [] }
        return items.compactMap(frame(of:))
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
            let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID()
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &origin),
            AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
