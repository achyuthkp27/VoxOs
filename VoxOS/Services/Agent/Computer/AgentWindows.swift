import AppKit
import ApplicationServices
import Foundation

/// Native app and window management via NSWorkspace, CGWindowList and the Accessibility
/// API. Coordinates are global screen points, top-left origin.
/// Ported from cursor-voice (MIT) WindowManager.
enum AgentWindows {

    @MainActor
    static func frontmostApp() -> [String: Any] {
        guard let app = NSWorkspace.shared.frontmostApplication else { return ["error": "no frontmost application"] }
        return [
            "name": app.localizedName ?? "", "bundle_id": app.bundleIdentifier ?? "", "pid": Int(app.processIdentifier),
        ]
    }

    @MainActor
    static func listApps() -> [[String: Any]] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let name = app.localizedName else { return nil }
                return ["name": name, "bundle_id": app.bundleIdentifier ?? "", "active": app.isActive]
            }
    }

    /// Launch by display name or bundle id; brings it forward if it is already running.
    @MainActor
    static func openApp(name: String) -> [String: Any] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ["error": "name is required"] }
        if let running = matchRunning(trimmed) {
            running.activate(options: [.activateAllWindows])
            return ["result": "opened \(running.localizedName ?? trimmed)"]
        }
        let workspace = NSWorkspace.shared
        var url: URL?
        if trimmed.contains("."), let byBundle = workspace.urlForApplication(withBundleIdentifier: trimmed) {
            url = byBundle
        }
        if url == nil {
            let base = trimmed.hasSuffix(".app") ? String(trimmed.dropLast(4)) : trimmed
            for directory in [
                "/Applications", "/System/Applications", "/System/Applications/Utilities",
                "\(NSHomeDirectory())/Applications",
            ] {
                let candidate = "\(directory)/\(base).app"
                if FileManager.default.fileExists(atPath: candidate) {
                    url = URL(fileURLWithPath: candidate)
                    break
                }
            }
        }
        guard let appURL = url else {
            return ["error": "could not find an app named \(trimmed) — try the exact name or its bundle id"]
        }
        workspace.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        return ["result": "opened \(appURL.deletingPathExtension().lastPathComponent)"]
    }

    @MainActor
    static func activateApp(query: String) -> [String: Any] {
        guard let app = matchRunning(query) else { return ["error": "no running app matching \"\(query)\""] }
        app.activate(options: [.activateAllWindows])
        return ["ok": true, "activated": app.localizedName ?? query]
    }

    static func listWindows() -> [[String: Any]] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [[String: Any]] = []
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
            let title = (w[kCGWindowName as String] as? String) ?? ""
            if owner.isEmpty, title.isEmpty { continue }
            var bounds: [String: Any] = [:]
            if let b = w[kCGWindowBounds as String] as? [String: Any] {
                bounds = ["x": b["X"] ?? 0, "y": b["Y"] ?? 0, "width": b["Width"] ?? 0, "height": b["Height"] ?? 0]
            }
            out.append([
                "app": owner, "title": title, "bounds": bounds,
                "window_id": (w[kCGWindowNumber as String] as? Int) ?? 0,
            ])
            if out.count >= 40 { break }
        }
        return out
    }

    @MainActor
    static func setWindowBounds(appQuery: String, x: Double, y: Double, width: Double, height: Double) -> [String: Any]
    {
        guard AXIsProcessTrusted() else { return ["error": "accessibility permission required"] }
        guard let app = matchRunning(appQuery) else { return ["error": "no running app matching \"\(appQuery)\""] }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var windowRef: AnyObject?
        if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) != .success
            || windowRef == nil
        {
            var windowsRef: AnyObject?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                let windows = windowsRef as? [AXUIElement], let first = windows.first
            else { return ["error": "no window found for \(app.localizedName ?? appQuery)"] }
            windowRef = first
        }
        guard let window = AgentAXTree.axElement(windowRef) else {
            return ["error": "no window found for \(app.localizedName ?? appQuery)"]
        }

        // Model-supplied geometry: keep the window on a display and large enough to grab.
        let desktop = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let clampedWidth = max(120, min(width, desktop.isNull ? width : desktop.width))
        let clampedHeight = max(80, min(height, desktop.isNull ? height : desktop.height))
        var position = CGPoint(x: x, y: y)
        if !desktop.isNull {
            position.x = max(desktop.minX, min(x, desktop.maxX - clampedWidth))
            position.y = max(desktop.minY, min(y, desktop.maxY - clampedHeight))
        }
        var size = CGSize(width: clampedWidth, height: clampedHeight)
        var okPosition = false
        var okSize = false
        if let value = AXValueCreate(.cgPoint, &position) {
            okPosition = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success
        }
        if let value = AXValueCreate(.cgSize, &size) {
            okSize = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success
        }
        return [
            "ok": okPosition && okSize, "app": app.localizedName ?? appQuery, "x": position.x, "y": position.y,
            "width": size.width, "height": size.height,
        ]
    }

    @MainActor
    private static func matchRunning(_ query: String) -> NSRunningApplication? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        return apps.first { $0.localizedName?.lowercased() == q || $0.bundleIdentifier?.lowercased() == q }
            ?? apps.first { $0.localizedName?.lowercased().contains(q) ?? false }
    }
}
