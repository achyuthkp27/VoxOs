import Foundation

/// The dashboard's two master switches, each over a whole side of VoxOS:
/// - the voice assistant: dictation and the Agent, by their shortcuts (fn, ⌃⌃, mode and
///   dictate-and-send shortcuts). Off, those shortcuts are hidden from the monitors exactly as a
///   shortcut being re-recorded is, so nothing is written over the user's own shortcuts.
/// - the notch: everything VoxOS draws there between dictations (Notch Home and its bands, the
///   idle tab, Claude Code's cards, the volume and brightness keys). Off, Claude Code's requests
///   stay in the terminal alone. Dictation's own recorder is part of the voice assistant.
enum MasterSwitches {
    static var voiceEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.voiceAssistantEnabled) }
    static var notchEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.notchMasterEnabled) }

    @MainActor
    static func setVoiceEnabled(_ enabled: Bool) {
        guard enabled != voiceEnabled else { return }
        UserDefaults.standard.set(enabled, forKey: DefaultsKeys.voiceAssistantEnabled)
        ActivityTrail.mark("voice assistant \(enabled ? "on" : "off")")
        // Each monitor reloads only for its own kind of shortcut: the main one for recording
        // shortcuts, the mode one for mode shortcuts.
        NotificationCenter.default.post(name: ShortcutStore.shortcutDidChange, object: ShortcutAction.primaryRecording)
        NotificationCenter.default.post(name: ShortcutStore.shortcutDidChange, object: ShortcutAction.mode(UUID()))
    }

    @MainActor
    static func setNotchEnabled(_ enabled: Bool) {
        guard enabled != notchEnabled else { return }
        UserDefaults.standard.set(enabled, forKey: DefaultsKeys.notchMasterEnabled)
        ActivityTrail.mark("notch \(enabled ? "on" : "off")")
        ClaudeCodeIntegration.shared.notchSwitchChanged()
    }
}

extension ShortcutAction {
    /// Starts dictation or the Agent: what the voice assistant switch turns off.
    var isVoice: Bool {
        switch self {
        case .primaryRecording, .secondaryRecording, .agentDoubleTap, .dictateAndSend, .mode, .captureSystemAudio:
            return true
        default:
            return false
        }
    }
}
