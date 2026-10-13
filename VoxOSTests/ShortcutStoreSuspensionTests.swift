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
}
