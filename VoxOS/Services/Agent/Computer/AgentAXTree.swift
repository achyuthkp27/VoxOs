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
        // Our own windows are served in-process on this thread, which builds SwiftUI's
        // accessibility tree off the main queue and trips SwiftData's queue assert.
        guard app.processIdentifier != AgentSelfGuard.ownPID else { return [] }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 1.0)

        var roots: [AXUIElement] = []
        if let focused = axElement(copyAttribute(axApp, kAXFocusedWindowAttribute)) {
            roots = [focused]
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
        guard AXIsProcessTrusted(), !AgentSelfGuard.isFrontmost else { return nil }
        let system = AXUIElementCreateSystemWide()
        guard let focused = axElement(copyAttribute(system, kAXFocusedUIElementAttribute)),
            !AgentSelfGuard.isOwn(focused)
        else { return nil }
        return stringFrom(copyAttribute(focused, kAXValueAttribute))
    }

    /// What keyboard input would land in right now: the focused element's role and its window.
    struct FocusedTarget: Equatable {
        let role: String
        let windowTitle: String
    }

    /// nil when it cannot be told (no Accessibility permission, VoxOS itself in front, or an app
    /// that exposes no focused element) — callers then type as before rather than guess.
    static func focusedTarget() -> FocusedTarget? {
        guard AXIsProcessTrusted(), !AgentSelfGuard.isFrontmost else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1.0)
        guard let focused = axElement(copyAttribute(system, kAXFocusedUIElementAttribute)),
            !AgentSelfGuard.isOwn(focused)
        else { return nil }
        AXUIElementSetMessagingTimeout(focused, 1.0)
        let role = stringFrom(copyAttribute(focused, kAXRoleAttribute))
        guard !role.isEmpty else { return nil }
        let window = axElement(copyAttribute(focused, kAXWindowAttribute))
        let title = window.map { stringFrom(copyAttribute($0, kAXTitleAttribute)) } ?? ""
        return FocusedTarget(role: role, windowTitle: title)
    }

    /// Roles that never take typed text. Only these block typing: an unknown role (custom views,
    /// web content, terminals) still gets the text, since a wrong refusal is worse than a miss.
    static let nonTextRoles: Set<String> = [
        "AXList", "AXOutline", "AXTable", "AXRow", "AXCell", "AXBrowser", "AXButton", "AXMenuButton",
        "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXWindow", "AXSheet", "AXToolbar", "AXImage",
        "AXSplitGroup", "AXTabGroup", "AXMenu", "AXMenuItem", "AXMenuBar",
    ]

    static func acceptsTyping(role: String) -> Bool {
        !nonTextRoles.contains(role)
    }

    /// The characters either side of the insertion point in the focused text field.
    ///
    /// Returns nil when there is no usable answer — no Accessibility permission, no focused text
    /// element, a selection rather than a caret, or an app that does not expose its selected
    /// range. Callers treat nil as "do not guess" rather than as "nothing is there", because
    /// inventing spacing from a wrong answer shifts the user's text.
    static func insertionContext() -> (before: Character?, after: Character?)? {
        guard AXIsProcessTrusted(), !AgentSelfGuard.isFrontmost else { return nil }
        // This runs on the paste path right after a dictation. The default AX timeout is six
        // seconds per call and an app that is busy (or has a hung AX server) blocks each one, so
        // bound it like enumerateFrontmost does rather than stall the paste.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 1.0)
        guard let focused = axElement(copyAttribute(system, kAXFocusedUIElementAttribute)),
            !AgentSelfGuard.isOwn(focused)
        else {
            return nil
        }
        AXUIElementSetMessagingTimeout(focused, 1.0)

        // Whatever the foreign app returns; some AX bridges hand back an NSValue here, and a
        // force cast trapped mid-dictation.
        guard let rangeValue = copyAttribute(focused, kAXSelectedTextRangeAttribute),
            CFGetTypeID(rangeValue) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(rangeValue, to: AXValue.self), .cfRange, &range) else { return nil }

        // A non-empty selection is about to be replaced, so neither side describes what the
        // inserted text will sit between.
        guard range.length == 0 else { return nil }
        let caret = range.location
        guard caret >= 0 else { return nil }

        // Only the two UTF-16 units around the caret are needed. Ask for just that window first:
        // copying kAXValueAttribute hands over the whole document, which for a long editor
        // buffer is megabytes marshalled over the AX connection on every paste. Apps that do not
        // implement the parameterized read fall back to the full value.
        if let window = stringForRange(focused, location: max(0, caret - 1), length: caret == 0 ? 1 : 2) {
            let utf16 = Array(window.utf16)
            let caretInWindow = caret == 0 ? 0 : 1
            // The app returned fewer units than asked: the caret is at the end, so there is
            // nothing after it, and (when it returned none) the field is empty.
            guard !utf16.isEmpty else { return nil }
            return (before: character(utf16, at: caretInWindow - 1), after: character(utf16, at: caretInWindow))
        }

        // stringFrom yields "" for a non-text element rather than nil, and an empty field has no
        // neighbouring characters to report either way.
        let value = stringFrom(copyAttribute(focused, kAXValueAttribute))
        guard !value.isEmpty else { return nil }

        // AX reports UTF-16 offsets; anything outside the string means the two are out of step
        // and the answer cannot be trusted.
        let utf16 = Array(value.utf16)
        guard caret <= utf16.count else { return nil }

        return (before: character(utf16, at: caret - 1), after: character(utf16, at: caret))
    }

    private static func character(_ utf16: [UInt16], at index: Int) -> Character? {
        guard index >= 0, index < utf16.count else { return nil }
        return String(utf16CodeUnits: [utf16[index]], count: 1).first
    }

    /// `kAXStringForRangeParameterizedAttribute` for a UTF-16 range; nil when the app does not
    /// support it (or the range is out of bounds), so the caller can fall back to the full value.
    private static func stringForRange(_ element: AXUIElement, location: Int, length: Int) -> String? {
        var range = CFRange(location: location, length: length)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: AnyObject?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value)
        guard status == .success else { return nil }
        // Some apps answer with an attributed string; either spelling is fine here.
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
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
        if let p = axValue(copyAttribute(element, kAXPositionAttribute)) {
            AXValueGetValue(p, .cgPoint, &pos)
        }
        if let s = axValue(copyAttribute(element, kAXSizeAttribute)) {
            AXValueGetValue(s, .cgSize, &size)
        }
        return CGRect(origin: pos, size: size)
    }

    /// Accessibility attributes are untyped CF values; a misbehaving app can hand back anything.
    static func axElement(_ value: AnyObject?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func axValue(_ value: AnyObject?) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXValue.self)
    }

    private static func stringFrom(_ any: AnyObject?) -> String {
        if let s = any as? String { return s }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }
}
