import AppKit
import ApplicationServices
import CoreGraphics

/// Synthesises mouse and keyboard events so the agent can physically drive the Mac.
/// All coordinates are GLOBAL screen points with a top-left origin — the same space the
/// Accessibility API reports element frames in and that `list_windows` returns — so a
/// value read from one tool can be fed straight into another. Requires Accessibility
/// permission; without it `CGEvent.post` silently does nothing.
/// Ported from cursor-voice (MIT) InputSynth.
enum AgentInputSynth {

    /// Stamped into every event we post so our own monitors can tell agent input from the user's.
    static let eventUserDataMarker: Int64 = 0x564F_584F_5341_4754  // "VOXOSAGT"

    static var isAccessibilityGranted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestAccessibility(prompt: Bool = true) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    // MARK: - Mouse

    static func move(to point: CGPoint) {
        post(.mouseMoved, at: point, button: .left)
    }

    static func click(at point: CGPoint, button: CGMouseButton = .left, count: Int = 1) {
        let (down, up): (CGEventType, CGEventType) = {
            switch button {
            case .left: return (.leftMouseDown, .leftMouseUp)
            case .right: return (.rightMouseDown, .rightMouseUp)
            default: return (.otherMouseDown, .otherMouseUp)
            }
        }()
        for i in 1...max(1, count) {
            postClick(down, at: point, button: button, clickState: i)
            postClick(up, at: point, button: button, clickState: i)
        }
    }

    static func drag(from: CGPoint, to: CGPoint, durationMs: Int = 350) {
        postClick(.leftMouseDown, at: from, button: .left, clickState: 1)
        let steps = max(8, durationMs / 16)
        let interval = TimeInterval(durationMs) / TimeInterval(steps) / 1000
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            post(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), button: .left)
            Thread.sleep(forTimeInterval: interval)
        }
        postClick(.leftMouseUp, at: to, button: .left, clickState: 1)
    }

    static func scroll(deltaX: Int32, deltaY: Int32) {
        let event = CGEvent(
            scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
            wheel1: deltaY, wheel2: deltaX, wheel3: 0)
        event?.setIntegerValueField(.eventSourceUserData, value: eventUserDataMarker)
        event?.post(tap: .cghidEventTap)
    }

    // MARK: - Keyboard

    /// Press a named key with optional modifiers (cmd, shift, option, control).
    @discardableResult
    static func pressKey(_ key: String, modifiers: [String] = []) -> Bool {
        guard let code = keyCode(for: key) else { return false }
        var flags: CGEventFlags = []
        for m in modifiers.map({ $0.lowercased() }) {
            switch m {
            case "cmd", "command", "⌘": flags.insert(.maskCommand)
            case "shift", "⇧": flags.insert(.maskShift)
            case "opt", "option", "alt", "⌥": flags.insert(.maskAlternate)
            case "ctrl", "control", "⌃": flags.insert(.maskControl)
            default: break
            }
        }
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: keyDown)
            event?.flags = flags
            event?.setIntegerValueField(.eventSourceUserData, value: eventUserDataMarker)
            event?.post(tap: .cghidEventTap)
        }
        return true
    }

    static let modifierNames: Set<String> = [
        "cmd", "command", "shift", "option", "opt", "alt", "control", "ctrl", "⌘", "⇧", "⌥", "⌃",
    ]

    // MARK: - Plumbing

    private static let source: CGEventSource? = CGEventSource(stateID: .privateState)

    private static func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton) {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        event?.setIntegerValueField(.eventSourceUserData, value: eventUserDataMarker)
        event?.post(tap: .cghidEventTap)
    }

    private static func postClick(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int) {
        let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event?.setIntegerValueField(.eventSourceUserData, value: eventUserDataMarker)
        event?.post(tap: .cghidEventTap)
    }

    private static func keyCode(for name: String) -> Int? {
        switch name.lowercased() {
        case "return", "enter": return 36
        case "tab": return 48
        case "space": return 49
        case "delete", "backspace": return 51
        case "forwarddelete": return 117
        case "escape", "esc": return 53
        case "up": return 126
        case "down": return 125
        case "left": return 123
        case "right": return 124
        case "home": return 115
        case "end": return 119
        case "pageup": return 116
        case "pagedown": return 121
        case "f1": return 122
        case "f2": return 120
        case "f3": return 99
        case "f4": return 118
        case "f5": return 96
        case "f6": return 97
        case "f7": return 98
        case "f8": return 100
        case "f9": return 101
        case "f10": return 109
        case "f11": return 103
        case "f12": return 111
        case "/", "slash": return 44
        case ".", "period": return 47
        case ",", "comma": return 43
        case "-", "minus": return 27
        case "=", "equals": return 24
        default: break
        }
        let map: [String: Int] = [
            "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38,
            "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17,
            "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
            "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
        ]
        return map[name.lowercased()]
    }
}
