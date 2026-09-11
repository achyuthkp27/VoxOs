import AppKit
import ApplicationServices
import Foundation

/// The UI element under the mouse pointer. Captured at the start of every recording so
/// "click this", "reply to that", "what is this" resolve to what the user is pointing at,
/// and exposed live to the agent as the `element_under_cursor` tool.
enum AgentPointerElement {

    struct Info {
        let app: String
        let bundleId: String
        let windowTitle: String
        let role: String
        let title: String
        let value: String
        let description: String
        /// Global screen points, top-left origin — what `mouse_click` expects.
        let frame: CGRect
        /// Nearest clickable ancestor when the hit element itself is passive text/image.
        let actionable: (role: String, title: String, frame: CGRect)?
        let pointer: CGPoint

        var centre: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

        /// Plain-text block for the recording context.
        var promptDescription: String {
            var lines: [String] = []
            lines.append("app: \(app)" + (windowTitle.isEmpty ? "" : " — window: \(windowTitle)"))
            lines.append("pointer: x=\(Int(pointer.x)) y=\(Int(pointer.y))")
            lines.append("element: \(role)" + (title.isEmpty ? "" : " \"\(title)\""))
            if !value.isEmpty { lines.append("value: \(value)") }
            if !description.isEmpty { lines.append("description: \(description)") }
            if frame.width > 0 {
                lines.append("centre: x=\(Int(frame.midX)) y=\(Int(frame.midY)) size=\(Int(frame.width))×\(Int(frame.height))")
            }
            if let actionable {
                lines.append(
                    "clickable parent: \(actionable.role) \"\(actionable.title)\" centre: x=\(Int(actionable.frame.midX)) y=\(Int(actionable.frame.midY))"
                )
            }
            return lines.joined(separator: "\n")
        }

        var toolResult: [String: Any] {
            var result: [String: Any] = [
                "app": app, "bundle_id": bundleId, "window": windowTitle,
                "role": role, "title": title, "value": value, "description": description,
                "x": Int(frame.midX), "y": Int(frame.midY),
                "width": Int(frame.width), "height": Int(frame.height),
                "pointer_x": Int(pointer.x), "pointer_y": Int(pointer.y),
            ]
            if let actionable {
                result["clickable_parent"] = [
                    "role": actionable.role, "title": actionable.title,
                    "x": Int(actionable.frame.midX), "y": Int(actionable.frame.midY),
                ]
            }
            return result
        }
    }

    private static let clickableRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXSearchField", "AXMenuItem", "AXMenuButton",
        "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXTab", "AXComboBox", "AXRow", "AXCell",
    ]

    /// Where the pointer is right now, in global top-left coordinates.
    @MainActor
    static func pointerLocation() -> CGPoint {
        let cocoa = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: cocoa.x, y: primaryHeight - cocoa.y)
    }

    /// Resolves the element at the pointer. Accessibility IPC — call off the main thread
    /// (the frontmost app may be slow to answer).
    static func capture(at point: CGPoint) -> Info? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1.0)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit) == .success,
            let element = hit
        else { return nil }

        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let app = NSRunningApplication(processIdentifier: pid)
        // Ignore our own windows (the recorder panel sits under the pointer during a hotkey press).
        if app?.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }

        let role = string(element, kAXRoleAttribute)
        let title = firstNonEmpty(
            string(element, kAXTitleAttribute), string(element, kAXDescriptionAttribute),
            string(element, kAXHelpAttribute), string(element, "AXPlaceholderValue"))
        let value = String(string(element, kAXValueAttribute).prefix(400))
        let description = role == "AXStaticText" ? "" : string(element, kAXDescriptionAttribute)
        let windowTitle = AgentAXTree.axElement(copy(element, kAXWindowAttribute)).map { string($0, kAXTitleAttribute) } ?? ""

        var actionable: (String, String, CGRect)?
        if !clickableRoles.contains(role) {
            var cursor: AXUIElement? = AgentAXTree.axElement(copy(element, kAXParentAttribute))
            var depth = 0
            while let parent = cursor, depth < 5 {
                let parentRole = string(parent, kAXRoleAttribute)
                if clickableRoles.contains(parentRole) {
                    let parentTitle = firstNonEmpty(
                        string(parent, kAXTitleAttribute), string(parent, kAXDescriptionAttribute),
                        string(parent, kAXValueAttribute))
                    actionable = (parentRole, String(parentTitle.prefix(120)), frame(of: parent))
                    break
                }
                cursor = AgentAXTree.axElement(copy(parent, kAXParentAttribute))
                depth += 1
            }
        }

        return Info(
            app: app?.localizedName ?? "", bundleId: app?.bundleIdentifier ?? "", windowTitle: windowTitle,
            role: role, title: String(title.prefix(200)), value: value, description: description,
            frame: frame(of: element), actionable: actionable, pointer: point)
    }

    // MARK: - Private

    private static func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String {
        let any = copy(element, attribute)
        if let s = any as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }

    private static func firstNonEmpty(_ values: String...) -> String {
        values.first { !$0.isEmpty } ?? ""
    }

    private static func frame(of element: AXUIElement) -> CGRect {
        var pos = CGPoint.zero
        var size = CGSize.zero
        if let p = copy(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID() {
            AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &pos)
        }
        if let s = copy(element, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() {
            AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size)
        }
        return CGRect(origin: pos, size: size)
    }
}
