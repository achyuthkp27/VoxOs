import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import ScreenCaptureKit
import SwiftUI
import os

/// The window switcher: Right Command (or the key chosen for the app switcher) and Tab shows the
/// windows on this Space as a grid, the most recent first, with the previous one picked, then the
/// minimized windows and those of hidden apps. Tab, Shift-Tab and the arrows move; letting go of
/// the key, Return or a click switches to the window; Escape leaves. On the picked window W closes
/// it, M minimizes it, H hides its app and Q twice quits it; / starts a search through apps and
/// window titles. A grid taller than the screen scrolls.
///
/// Titles and thumbnails need Screen Recording; without it each window shows its app's icon and
/// name. Raising a window needs Accessibility, which the app switcher's keys already need.
@MainActor
final class WindowSwitcher: ObservableObject {
    static let shared = WindowSwitcher()

    struct Window: Identifiable, Equatable {
        let id: CGWindowID
        let pid: pid_t
        let appName: String
        let bundleID: String?
        let title: String
        let frame: CGRect
        var place: Place = .onScreen

        /// The title, or the app's name when the window has none (or it cannot be read).
        var label: String { title.isEmpty ? appName : title }
    }

    /// Where a window is: on this Space, or out of sight and listed after those that are.
    enum Place: Equatable {
        case onScreen
        case minimized
        case hidden
    }

    /// A window as Accessibility sees it, to tell a minimized or hidden one from the off-screen
    /// helper windows apps keep.
    struct AXWindowInfo: Equatable {
        let frame: CGRect
        let title: String
        let minimized: Bool
    }

    enum Event {
        case open(backwards: Bool)
        case key(code: Int64, flags: UInt64)
        case release
    }

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: DefaultsKeys.windowSwitcherEnabled) as? Bool ?? true
    }
    /// Columns at most; fewer windows take fewer.
    static let maxColumns = 5
    /// The largest thumbnail, in points.
    static let thumbnailSize = CGSize(width: 200, height: 124)

    @Published private(set) var windows: [Window] = []
    @Published private(set) var selected = 0
    @Published private(set) var query = ""
    @Published private(set) var searching = false
    @Published private(set) var thumbnails: [CGWindowID: NSImage] = [:]
    /// The app Q was pressed on once: pressing it again quits that app.
    @Published private(set) var quitArmed: pid_t?
    /// The tallest the grid gets before it scrolls, from the screen it shows on.
    @Published private(set) var maxGridHeight: CGFloat = 600

    var isOpen: Bool { panel != nil }

    /// The windows the search leaves, in order.
    var shown: [Window] { Self.filter(windows, query: query) }
    var columns: Int { Self.columns(for: shown.count) }

    private var panel: NSPanel?
    private var thumbnailTask: Task<Void, Never>?
    /// Where the pointer was when the keys last moved the pick (or the grid opened). A tile that
    /// comes under a pointer that has not moved since — the grid scrolling to the pick, or opening
    /// under it — does not take the pick; only moving the mouse does.
    private var pointerAtKeys: CGPoint?
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "WindowSwitcher")

    private init() {}

    // MARK: Keys

    func handle(_ event: Event) {
        switch event {
        case .open(let backwards):
            if panel == nil {
                open(backwards: backwards)
            } else {
                pointerAtKeys = NSEvent.mouseLocation
                move(by: backwards ? -1 : 1)
            }
        case .key(let code, let flags):
            key(code, shift: flags & UInt64(CGEventFlags.maskShift.rawValue) != 0)
        case .release:
            commit()
        }
    }

    private func key(_ code: Int64, shift: Bool) {
        guard panel != nil else { return }
        pointerAtKeys = NSEvent.mouseLocation
        let armed = quitArmed
        quitArmed = nil
        switch Int(code) {
        case kVK_Tab: move(by: shift ? -1 : 1)
        case kVK_LeftArrow: move(by: -1)
        case kVK_RightArrow: move(by: 1)
        case kVK_UpArrow: move(by: -columns)
        case kVK_DownArrow: move(by: columns)
        case kVK_Return, kVK_ANSI_KeypadEnter: commit()
        case kVK_Escape: close()
        case kVK_Delete:
            if !query.isEmpty {
                query.removeLast()
                selected = 0
            } else {
                searching = false
            }
        default:
            // The search reads the layout selected; the commands read the ASCII-capable one, so W,
            // M, H and Q stay put under a Cyrillic or Greek layout.
            let typed = AppSwitcher.shared.typedKeys[code]
            let latin = AppSwitcher.shared.latinKeys[code]
            if searching {
                guard let text = typed ?? latin else { return }
                query += text
                selected = 0
            } else if typed == "/" || latin == "/" {
                searching = true
            } else if let latin {
                act(on: latin, quitArmed: armed)
            }
        }
    }

    // MARK: Opening and closing

    private func open(backwards: Bool) {
        let found = Self.currentWindows()
        guard !found.isEmpty else {
            AppSwitcher.shared.closeWindowSwitcher()
            return
        }
        windows = found
        query = ""
        searching = false
        thumbnails = [:]
        quitArmed = nil
        pointerAtKeys = NSEvent.mouseLocation
        selected = Self.firstSelection(count: found.count, backwards: backwards)
        showPanel()
        loadThumbnails(for: found)
        ActivityTrail.mark("window switcher opened")
    }

    /// Switches to the picked window and closes.
    func commit() {
        let list = shown
        let window = list.indices.contains(selected) ? list[selected] : nil
        close()
        if let window { Self.focus(window) }
    }

    func close() {
        thumbnailTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
        AppSwitcher.shared.closeWindowSwitcher()
    }

    /// From the grid: a window under the pointer is picked once the mouse moves; a click switches
    /// to it.
    func pick(_ id: CGWindowID) {
        if let still = pointerAtKeys, still == NSEvent.mouseLocation { return }
        pointerAtKeys = nil
        select(id)
    }

    func choose(_ id: CGWindowID) {
        select(id)
        commit()
    }

    private func select(_ id: CGWindowID) {
        if let index = shown.firstIndex(where: { $0.id == id }) { selected = index }
    }

    private func move(by step: Int) {
        selected = Self.moved(selected, by: step, count: shown.count)
    }

    // MARK: Actions

    private func act(on letter: String, quitArmed armed: pid_t?) {
        let list = shown
        guard list.indices.contains(selected) else { return }
        let window = list[selected]
        let app = NSRunningApplication(processIdentifier: window.pid)
        switch letter {
        case "w":
            guard let ax = Self.axWindow(for: window) else { return }
            var button: AnyObject?
            if AXUIElementCopyAttributeValue(ax, kAXCloseButtonAttribute as CFString, &button) == .success,
                let button
            {
                AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
            }
            remove { $0.id == window.id }
        case "m":
            guard let ax = Self.axWindow(for: window) else { return }
            AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
            remove { $0.id == window.id }
        case "h":
            app?.hide()
            remove { $0.pid == window.pid }
        case "q":
            // One stray Q while tabbing should not lose an app's work: the first only asks.
            guard armed == window.pid else {
                quitArmed = window.pid
                return
            }
            app?.terminate()
            remove { $0.pid == window.pid }
        default:
            return
        }
    }

    private func remove(where gone: (Window) -> Bool) {
        windows.removeAll(where: gone)
        if shown.isEmpty {
            close()
        } else {
            selected = min(selected, shown.count - 1)
            resizePanel()
        }
    }

    // MARK: Panel

    private func showPanel() {
        // The panel's padding, footer and search line take about this much besides the grid.
        let chrome: CGFloat = 120
        if let visible = NSScreen.underPointer?.visibleFrame {
            maxGridHeight = max(200, visible.height * 0.9 - chrome)
        }
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: WindowSwitcherView(switcher: self))
        self.panel = panel
        resizePanel()
        panel.orderFrontRegardless()
    }

    private func resizePanel() {
        guard let panel, let view = panel.contentView else { return }
        let size = view.fittingSize
        guard let visible = NSScreen.underPointer?.visibleFrame else { return }
        let origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    // MARK: Thumbnails

    private func loadThumbnails(for windows: [Window]) {
        thumbnailTask?.cancel()
        guard CGPreflightScreenCaptureAccess() else { return }
        let ids = Set(windows.map(\.id))
        // Sized for the screen the panel shows on, so a Retina and a plain display both get sharp
        // thumbnails at the right size.
        let scale = NSScreen.underPointer?.backingScaleFactor ?? 2
        let maxPixels = CGSize(width: Self.thumbnailSize.width * scale, height: Self.thumbnailSize.height * scale)
        thumbnailTask = Task { @MainActor [weak self] in
            guard
                let content = try? await SCShareableContent.excludingDesktopWindows(
                    true, onScreenWindowsOnly: false)
            else { return }
            let targets = content.windows.filter { ids.contains($0.windowID) }
            await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                for target in targets {
                    let filter = SCContentFilter(desktopIndependentWindow: target)
                    let configuration = SCStreamConfiguration()
                    let fit = Self.fitted(target.frame.size, in: maxPixels)
                    configuration.width = max(1, Int(fit.width))
                    configuration.height = max(1, Int(fit.height))
                    configuration.showsCursor = false
                    let id = target.windowID
                    group.addTask {
                        let image = try? await SCScreenshotManager.captureImage(
                            contentFilter: filter, configuration: configuration)
                        return (id, image)
                    }
                }
                for await (id, image) in group {
                    guard let self, !Task.isCancelled, let image else { continue }
                    self.thumbnails[id] = NSImage(cgImage: image, size: .zero)
                }
            }
        }
    }

    // MARK: Windows

    /// The windows on this Space, front to back: regular apps' windows at the normal level, big
    /// enough to be a window and not see-through, leaving out VoxOS's own. Then the minimized
    /// windows and those of hidden apps, each checked against Accessibility, since apps also keep
    /// off-screen windows that are not windows to the person using them.
    static func currentWindows() -> [Window] {
        let info =
            CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var apps: [pid_t: (name: String, bundleID: String?)] = [:]
        var hidden = Set<pid_t>()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            apps[app.processIdentifier] = (app.localizedName ?? "", app.bundleIdentifier)
            if app.isHidden { hidden.insert(app.processIdentifier) }
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let onScreen = info.filter { ($0[kCGWindowIsOnscreen as String] as? Bool) == true }
        let offScreen = info.filter { ($0[kCGWindowIsOnscreen as String] as? Bool) != true }
        let shown = windows(from: onScreen, apps: apps, ownPID: ownPID)
        let unseen = windows(from: offScreen, apps: apps, ownPID: ownPID)
        var ax: [pid_t: [AXWindowInfo]] = [:]
        for pid in Set(unseen.map(\.pid)) { ax[pid] = axWindows(of: pid) }
        return shown + outOfSight(unseen, hidden: hidden, ax: ax)
    }

    /// The off-screen windows worth listing: those Accessibility knows, of a hidden app or
    /// minimized, marked so. The rest are an app's helper windows, which are left out.
    nonisolated static func outOfSight(_ candidates: [Window], hidden: Set<pid_t>, ax: [pid_t: [AXWindowInfo]])
        -> [Window]
    {
        candidates.compactMap { window in
            guard let known = ax[window.pid], !known.isEmpty,
                let index = bestMatch(
                    frame: window.frame, title: window.title, among: known.map { ($0.frame, $0.title) })
            else { return nil }
            var listed = window
            if known[index].minimized {
                listed.place = .minimized
            } else if hidden.contains(window.pid) {
                listed.place = .hidden
            } else {
                return nil
            }
            return listed
        }
    }

    /// An app's windows as Accessibility sees them, waiting at most a moment for an app that
    /// does not answer.
    private static func axWindows(of pid: pid_t) -> [AXWindowInfo] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
            let elements = value as? [AXUIElement]
        else { return [] }
        return elements.map { element in
            AXWindowInfo(
                frame: axFrame(element) ?? .null, title: axString(element, kAXTitleAttribute) ?? "",
                minimized: axBool(element, kAXMinimizedAttribute) == true)
        }
    }

    nonisolated static func windows(
        from info: [[String: Any]], apps: [pid_t: (name: String, bundleID: String?)], ownPID: pid_t
    ) -> [Window] {
        info.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != ownPID,
                let app = apps[pid],
                let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                let frame = CGRect(dictionaryRepresentation: bounds),
                frame.width >= 80, frame.height >= 60
            else { return nil }
            if let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha < 0.05 { return nil }
            return Window(
                id: id, pid: pid, appName: app.name, bundleID: app.bundleID,
                title: entry[kCGWindowName as String] as? String ?? "", frame: frame)
        }
    }

    /// The previous window, as ⌘Tab picks the previous app; going backwards, the last one.
    nonisolated static func firstSelection(count: Int, backwards: Bool) -> Int {
        guard count > 1 else { return 0 }
        return backwards ? count - 1 : 1
    }

    /// A step through the grid, wrapping at either end.
    nonisolated static func moved(_ index: Int, by step: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + step) % count + count) % count
    }

    nonisolated static func columns(for count: Int) -> Int { max(1, min(count, maxColumns)) }

    /// The windows whose app name and title hold the query's characters in order, ignoring case;
    /// all of them for an empty query.
    nonisolated static func filter(_ windows: [Window], query: String) -> [Window] {
        let needle = query.lowercased().filter { !$0.isWhitespace }
        guard !needle.isEmpty else { return windows }
        return windows.filter { window in
            var rest = Substring(needle)
            for character in "\(window.appName) \(window.title)".lowercased() where rest.first == character {
                rest = rest.dropFirst()
                if rest.isEmpty { return true }
            }
            return rest.isEmpty
        }
    }

    nonisolated static func fitted(_ size: CGSize, in bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height, 1)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    // MARK: Focusing

    /// Raises the window over its app's others, then brings the app forward as the Dock would,
    /// which macOS allows from an app in the background.
    static func focus(_ window: Window) {
        guard let app = NSRunningApplication(processIdentifier: window.pid) else { return }
        let ax = axWindow(for: window)
        if let ax {
            if axBool(ax, kAXMinimizedAttribute) == true {
                AXUIElementSetAttributeValue(ax, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            AXUIElementSetAttributeValue(ax, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(ax, kAXRaiseAction as CFString)
        }
        guard let url = app.bundleURL else {
            app.activate()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            // Activating can put the app's last front window back on top; raise the chosen one again.
            Task { @MainActor in
                if let again = axWindow(for: window) { AXUIElementPerformAction(again, kAXRaiseAction as CFString) }
            }
        }
    }

    /// The Accessibility element for a window, found among its app's windows by frame, then title.
    static func axWindow(for window: Window) -> AXUIElement? {
        let app = AXUIElementCreateApplication(window.pid)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
            let elements = value as? [AXUIElement], !elements.isEmpty
        else { return nil }
        let candidates = elements.map { element -> (frame: CGRect, title: String) in
            (axFrame(element) ?? .null, axString(element, kAXTitleAttribute) ?? "")
        }
        return bestMatch(frame: window.frame, title: window.title, among: candidates).map { elements[$0] }
    }

    /// The candidate with the same frame (to a point), else the same title, else nothing.
    nonisolated static func bestMatch(frame: CGRect, title: String, among candidates: [(frame: CGRect, title: String)])
        -> Int?
    {
        func near(_ a: CGRect, _ b: CGRect) -> Bool {
            !a.isNull && abs(a.minX - b.minX) <= 1 && abs(a.minY - b.minY) <= 1 && abs(a.width - b.width) <= 1
                && abs(a.height - b.height) <= 1
        }
        if let index = candidates.firstIndex(where: { near($0.frame, frame) && (title.isEmpty || $0.title == title) }) {
            return index
        }
        if let index = candidates.firstIndex(where: { near($0.frame, frame) }) { return index }
        if !title.isEmpty, let index = candidates.firstIndex(where: { $0.title == title }) { return index }
        return nil
    }

    private static func axFrame(_ element: AXUIElement) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
            AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
            let positionValue, let sizeValue
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
            AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? NSNumber)?.boolValue
    }
}

extension NSScreen {
    /// The screen the pointer is on, where the switcher's panels show.
    @MainActor static var underPointer: NSScreen? {
        screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? main
    }
}
