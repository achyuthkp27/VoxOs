import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import ScreenCaptureKit
import SwiftUI
import os

/// The window switcher: Right Command (or the key chosen for the app switcher) and Tab shows the
/// windows on this Space as a grid, the most recent first, with the previous one picked. Tab,
/// Shift-Tab and the arrows move; letting go of the key, Return or a click switches to the
/// window; Escape leaves. On the picked window W closes it, M minimizes it, H hides its app and
/// Q quits it; / starts a search through apps and window titles.
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

        /// The title, or the app's name when the window has none (or it cannot be read).
        var label: String { title.isEmpty ? appName : title }
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

    /// The windows the search leaves, in order.
    var shown: [Window] { Self.filter(windows, query: query) }
    var columns: Int { Self.columns(for: shown.count) }

    private var panel: NSPanel?
    private var thumbnailTask: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "WindowSwitcher")

    private init() {}

    // MARK: Keys

    func handle(_ event: Event) {
        switch event {
        case .open(let backwards):
            if panel == nil { open(backwards: backwards) } else { move(by: backwards ? -1 : 1) }
        case .key(let code, let flags):
            key(code, shift: flags & UInt64(CGEventFlags.maskShift.rawValue) != 0)
        case .release:
            commit()
        }
    }

    private func key(_ code: Int64, shift: Bool) {
        guard panel != nil else { return }
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
            guard let typed = AppSwitcher.shared.typedKeys[code] else { return }
            if searching {
                query += typed
                selected = 0
            } else if typed == "/" {
                searching = true
            } else {
                act(on: typed)
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

    /// From the grid: a window under the pointer is picked; a click switches to it.
    func pick(_ id: CGWindowID) {
        if let index = shown.firstIndex(where: { $0.id == id }) { selected = index }
    }

    func choose(_ id: CGWindowID) {
        pick(id)
        commit()
    }

    private func move(by step: Int) {
        selected = Self.moved(selected, by: step, count: shown.count)
    }

    // MARK: Actions

    private func act(on letter: String) {
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
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    // MARK: Thumbnails

    private func loadThumbnails(for windows: [Window]) {
        thumbnailTask?.cancel()
        guard CGPreflightScreenCaptureAccess() else { return }
        let ids = Set(windows.map(\.id))
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let maxPixels = CGSize(width: Self.thumbnailSize.width * scale, height: Self.thumbnailSize.height * scale)
        thumbnailTask = Task { @MainActor [weak self] in
            guard
                let content = try? await SCShareableContent.excludingDesktopWindows(
                    true, onScreenWindowsOnly: true)
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
    /// enough to be a window and not see-through, leaving out VoxOS's own.
    static func currentWindows() -> [Window] {
        let info =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var apps: [pid_t: (name: String, bundleID: String?)] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            apps[app.processIdentifier] = (app.localizedName ?? "", app.bundleIdentifier)
        }
        return windows(from: info, apps: apps, ownPID: ProcessInfo.processInfo.processIdentifier)
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
