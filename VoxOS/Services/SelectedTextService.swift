import ApplicationServices
import Foundation
import SelectedTextKit
import os

@MainActor
final class SelectedTextService {
    private static let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "SelectedTextService")
    private static let textManager = SelectedTextManager.shared
    private static let selectedTextStrategies: [TextStrategy] = [
        .accessibility,
        .menuAction,
        .appleScript,
    ]

    /// `allowClipboardCopy` adds a synthesised ⌘C as the last resort. Terminals (cmux, Ghostty,
    /// iTerm) and many Electron apps answer neither the Accessibility query nor the menu-item
    /// press, so without it a selection there reads as "nothing selected". The pasteboard is
    /// restored afterwards, but ⌘C in an app with no text selection can copy something else
    /// (files in Finder), so callers enable it only when a selection is mandatory.
    static func fetchSelectedText(allowClipboardCopy: Bool = false) async -> String? {
        guard AXIsProcessTrusted() else {
            logger.debug("Accessibility is not trusted; selected text capture skipped")
            return nil
        }

        // Terminals with their own selection API come first: for them every general route
        // below fails, and the synthesised ⌘C fallback costs a round trip for nothing.
        if let terminalSelection = await TerminalSelectionReader.selectionInFrontmostTerminal() {
            return normalized(terminalSelection)
        }

        let strategies = allowClipboardCopy ? selectedTextStrategies + [.shortcut] : selectedTextStrategies
        do {
            return normalized(try await textManager.getSelectedText(strategies: strategies))
        } catch {
            logger.debug("SelectedTextKit failed to capture selected text: \(error, privacy: .public)")
            return nil
        }
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
