import AppKit

/// The display the notch surfaces (Notch Home, Claude Code's cards) live on.
///
/// The display with a notch. With none — a desktop Mac, or a MacBook closed on an external
/// display — the primary display, where a virtual notch as tall as the menu bar hangs from the
/// top centre (see `NotchRecorderPanel.calculateWindowMetrics`). With "Follow the Display in
/// Use" on, the display holding the front app's window, notch or not.
@MainActor
enum NotchScreens {
    static var followsActiveDisplay: Bool {
        UserDefaults.standard.bool(forKey: DefaultsKeys.notchFollowsActiveDisplay)
    }

    static func target() -> NSScreen? {
        let screens = NSScreen.screens
        let chosen = choose(
            screens.map { (id: displayID($0), hasNotch: hasNotch($0)) },
            active: followsActiveDisplay ? activeDisplay() : nil)
        return screens.first { displayID($0) == chosen }
    }

    /// The display in use when asked for and still attached; otherwise the first with a notch;
    /// otherwise the primary display, which macOS lists first.
    nonisolated static func choose(
        _ screens: [(id: CGDirectDisplayID, hasNotch: Bool)], active: CGDirectDisplayID?
    ) -> CGDirectDisplayID? {
        if let active, screens.contains(where: { $0.id == active }) { return active }
        return screens.first(where: \.hasNotch)?.id ?? screens.first?.id
    }

    static func hasNotch(_ screen: NSScreen) -> Bool { screen.safeAreaInsets.top > 0 }

    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static func same(_ lhs: NSScreen?, _ rhs: NSScreen?) -> Bool {
        lhs.map(displayID) == rhs.map(displayID)
    }

    /// Read once per front app, not on every refresh: window bounds need no permission but are a
    /// trip to the window server.
    private static var activeCache: (app: pid_t, display: CGDirectDisplayID?)?

    /// The display holding the front app's frontmost window.
    static func activeDisplay() -> CGDirectDisplayID? {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        if let activeCache, activeCache.app == front { return activeCache.display }
        var display: CGDirectDisplayID?
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]],
            let window = list.first(where: {
                ($0[kCGWindowOwnerPID as String] as? Int32) == front && ($0[kCGWindowLayer as String] as? Int) == 0
            }),
            let bounds = (window[kCGWindowBounds as String] as? NSDictionary).flatMap({
                CGRect(dictionaryRepresentation: $0)
            })
        {
            var found: CGDirectDisplayID = 0
            var count: UInt32 = 0
            CGGetDisplaysWithPoint(CGPoint(x: bounds.midX, y: bounds.midY), 1, &found, &count)
            display = count > 0 ? found : nil
        }
        activeCache = (front, display)
        return display
    }
}
