import Carbon.HIToolbox
import Foundation
import Testing

@testable import VoxOS

/// Re-recording a shortcut must hide the old one from the monitors without persisting anything:
/// a crash mid-recording used to leave "cleared" in defaults and lose fn for good.
@Suite(.serialized)
struct ShortcutStoreSuspensionTests {

    @Test func suspensionHidesTheShortcutWithoutTouchingStorage() {
        let action = ShortcutAction.pasteLastTranscription
        // An odd combination nothing else claims, so the validator lets it through.
        let shortcut = Shortcut.key(keyCode: UInt16(kVK_ANSI_9), modifierFlags: [.control, .option])
        ShortcutStore.removeShortcutStorage(for: action)
        defer { ShortcutStore.removeShortcutStorage(for: action) }
        ShortcutStore.setShortcut(shortcut, for: action)

        ShortcutStore.suspend(action)
        #expect(ShortcutStore.shortcut(for: action) == nil, "monitors see no shortcut while recording")
        #expect(ShortcutStore.rawShortcut(for: action) == shortcut, "…but storage is untouched")
        #expect(!ShortcutStore.isShortcutCleared(for: action), "and nothing says cleared")

        ShortcutStore.resume(action)
        #expect(ShortcutStore.shortcut(for: action) == shortcut)
    }

    /// The dashboard's voice assistant switch hides the shortcuts that start dictation or the
    /// Agent, the same way, and leaves the others alone.
    @MainActor
    @Test func theVoiceSwitchHidesOnlyVoiceShortcuts() {
        let voice = ShortcutAction.secondaryRecording
        let other = ShortcutAction.pasteLastTranscription
        let voiceShortcut = Shortcut.key(keyCode: UInt16(kVK_ANSI_8), modifierFlags: [.control, .option])
        let otherShortcut = Shortcut.key(keyCode: UInt16(kVK_ANSI_9), modifierFlags: [.control, .option])
        let wasOn = MasterSwitches.voiceEnabled
        ShortcutStore.removeShortcutStorage(for: voice)
        ShortcutStore.removeShortcutStorage(for: other)
        defer {
            MasterSwitches.setVoiceEnabled(wasOn)
            ShortcutStore.removeShortcutStorage(for: voice)
            ShortcutStore.removeShortcutStorage(for: other)
        }
        ShortcutStore.setShortcut(voiceShortcut, for: voice)
        ShortcutStore.setShortcut(otherShortcut, for: other)
        MasterSwitches.setVoiceEnabled(true)

        MasterSwitches.setVoiceEnabled(false)
        #expect(ShortcutStore.shortcut(for: voice) == nil, "dictation's shortcut is not listened for")
        #expect(ShortcutStore.rawShortcut(for: voice) == voiceShortcut, "…and is kept")
        #expect(ShortcutStore.shortcut(for: other) == otherShortcut, "pasting the last one still works")
        #expect(ShortcutAction.agentDoubleTap.isVoice && ShortcutAction.mode(UUID()).isVoice)
        #expect(!ShortcutAction.openHistoryWindow.isVoice)

        MasterSwitches.setVoiceEnabled(true)
        #expect(ShortcutStore.shortcut(for: voice) == voiceShortcut)
    }
}
