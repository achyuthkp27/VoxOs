import AppKit
import ApplicationServices
import Foundation

/// Walks the macOS Accessibility tree of the frontmost app and exposes it as a flat list
/// of actionable elements. This is the reliable path for acting on UI — the element is
/// pressed through the Accessibility API, so no pixel hunting and no cursor movement.
/// Ported from cursor-voice (MIT) AXTree.
enum AgentAXTree {

    struct Element {
        let role: String
        let title: String
        let value: String
        /// title + value + help + description + AXIdentifier, lowercased, for fuzzy matching.
        let searchBlob: String
        /// Global screen points, top-left origin — the same space `CGEvent` posts into.
        let frame: CGRect
        let identifier: String
        let element: AXUIElement
    }

    /// Fire the element's AXPress action. Works on every standard button, menu item,
    /// checkbox and link without simulating a click — coordinate clicks are the fallback.
    static func tryPress(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    private static let interestingRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXSearchField",
        "AXMenuItem", "AXMenuButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXTabGroup", "AXTab", "AXComboBox", "AXOutline", "AXRow", "AXCell", "AXImage",
    ]

    /// Flat list of interesting elements from the frontmost app's focused window.
    static func enumerateFrontmost(maxDepth: Int = 14, maxElements: Int = 120) -> [Element] {
        guard AXIsProcessTrusted() else { return [] }
        guard let app = NSWorkspace.shared.frontmostApplication else { return [] }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var roots: [AXUIElement] = []
        if let focused = copyAttribute(axApp, kAXFocusedWindowAttribute) {
            roots = [focused as! AXUIElement]
        } else if let windows = copyAttribute(axApp, kAXWindowsAttribute) as? [AXUIElement] {
            roots = windows
        }
        if roots.isEmpty { roots = [axApp] }

        var results: [Element] = []
        var counter = 0
        for root in roots {
            walk(root, depth: 0, maxDepth: maxDepth, results: &results, counter: &counter, limit: maxElements)
            if results.count >= maxElements { break }
        }
        return results
    }

    /// Best match by title. Score: exact > prefix > contains > value > any attribute.
    static func bestMatch(in elements: [Element], name: String, role: String? = nil) -> Element? {
        let q = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let pool = role.flatMap { r in r.isEmpty ? nil : elements.filter { $0.role == r } } ?? elements

        func score(_ e: Element) -> Int {
            let t = e.title.lowercased()
            let v = e.value.lowercased()
            if t == q { return 1000 }
            if t.hasPrefix(q) { return 800 }
            if t.contains(q) { return 600 - abs(t.count - q.count) }
            if v.contains(q) { return 400 }
            if e.searchBlob.contains(q) { return 350 }
            return 0
        }
        return pool.map { (e: $0, s: score($0)) }
            .filter { $0.s > 0 }
            .max(by: { $0.s < $1.s })?.e
    }

    /// Text of the focused element (what the user is typing into), if any.
    static func focusedElementValue() -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        guard let focused = copyAttribute(system, kAXFocusedUIElementAttribute) else { return nil }
        return stringFrom(copyAttribute(focused as! AXUIElement, kAXValueAttribute))
    }

    // MARK: - Private

    private static func walk(
        _ element: AXUIElement, depth: Int, maxDepth: Int,
        results: inout [Element], counter: inout Int, limit: Int
    ) {
        if depth > maxDepth || results.count >= limit { return }

        let role = (copyAttribute(element, kAXRoleAttribute) as? String) ?? ""
        let title = (copyAttribute(element, kAXTitleAttribute) as? String) ?? ""
        let value = stringFrom(copyAttribute(element, kAXValueAttribute))
        let help = (copyAttribute(element, kAXHelpAttribute) as? String) ?? ""
        let desc = (copyAttribute(element, kAXDescriptionAttribute) as? String) ?? ""
        let axId = (copyAttribute(element, "AXIdentifier") as? String) ?? ""

        let displayTitle = !title.isEmpty ? title : !help.isEmpty ? help : !desc.isEmpty ? desc : value

        if interestingRoles.contains(role), !displayTitle.isEmpty {
            let frame = frameOf(element)
            if frame.width > 0, frame.height > 0 {
                counter += 1
                let blob = [displayTitle, value, help, desc, axId]
                    .filter { !$0.isEmpty }.joined(separator: " ").lowercased()
                results.append(
                    Element(
                        role: role, title: displayTitle, value: value, searchBlob: blob,
                        frame: frame, identifier: "el\(counter)", element: element))
            }
        }

        if let children = copyAttribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            for child in children {
                walk(child, depth: depth + 1, maxDepth: maxDepth, results: &results, counter: &counter, limit: limit)
                if results.count >= limit { return }
            }
        }
    }

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func frameOf(_ element: AXUIElement) -> CGRect {
        var pos = CGPoint.zero
        var size = CGSize.zero
        if let p = copyAttribute(element, kAXPositionAttribute) {
            AXValueGetValue(p as! AXValue, .cgPoint, &pos)
        }
        if let s = copyAttribute(element, kAXSizeAttribute) {
            AXValueGetValue(s as! AXValue, .cgSize, &size)
        }
        return CGRect(origin: pos, size: size)
    }

    private static func stringFrom(_ any: AnyObject?) -> String {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }
}
