import Foundation

/// "Send" for dictation: pressing Return after the text is pasted, either every time (a setting)
/// or once, for the dictation started or finished with fn+⌃.
@MainActor
enum DictationSend {
    static let pressReturnKey = "DictationPressReturnAfterPaste"
    static let stopWhenQuietKey = "DictationStopWhenQuiet"
    /// People pause more while dictating than while giving a command.
    static let extraDictationPause: TimeInterval = 0.7
    /// A one-off send left over from an abandoned recording must not fire much later.
    static let onceLifetime: TimeInterval = 10 * 60

    private(set) static var onceArmedAt: Date?

    static var pressReturnAlways: Bool { UserDefaults.standard.bool(forKey: pressReturnKey) }
    static var stopWhenQuiet: Bool { UserDefaults.standard.bool(forKey: stopWhenQuietKey) }

    static var dictationPause: TimeInterval { AgentAutoSend.pause + extraDictationPause }

    static func armOnce(now: Date = Date()) {
        onceArmedAt = now
    }

    static func clearOnce() {
        onceArmedAt = nil
    }

    /// The key to press after pasting. A mode's own auto-send key wins; otherwise Return when the
    /// setting is on or fn+⌃ armed a one-off send. Consumes the one-off.
    static func keyForPaste(modeKey: AutoSendKey, now: Date = Date()) -> AutoSendKey {
        let once = onceArmedAt.map { now.timeIntervalSince($0) <= onceLifetime } ?? false
        onceArmedAt = nil
        if modeKey.isEnabled { return modeKey }
        return once || pressReturnAlways ? .enter : .none
    }
}
