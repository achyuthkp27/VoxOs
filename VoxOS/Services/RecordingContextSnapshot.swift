import AppKit
import Foundation

struct RecordingContextSnapshot {
    var capturedAt = Date()
    var selectedText: String?
    var clipboardText: String?
    var screenText: String?
    /// What the mouse pointer was over when recording started ("click this", "reply to that").
    var pointerElement: String?
}

@MainActor
final class RecordingContextSnapshotStore {
    private(set) var snapshot = RecordingContextSnapshot()

    func updateSelectedText(_ text: String?) {
        snapshot.selectedText = Self.normalized(text)
    }

    func updateClipboardText(_ text: String?) {
        snapshot.clipboardText = Self.normalized(text)
    }

    func updateScreenText(_ text: String?) {
        snapshot.screenText = Self.normalized(text)
    }

    func updatePointerElement(_ text: String?) {
        snapshot.pointerElement = Self.normalized(text)
    }

    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
enum RecordingContextCaptureService {
    static func startCapture(into store: RecordingContextSnapshotStore) -> [Task<Void, Never>] {
        [
            Task { @MainActor in
                store.updateClipboardText(NSPasteboard.general.string(forType: .string))
            },
            Task { @MainActor in
                guard !Task.isCancelled else { return }
                let selectedText = await SelectedTextService.fetchSelectedText()
                guard !Task.isCancelled else { return }
                store.updateSelectedText(selectedText)
            },
            Task { @MainActor in
                guard AXIsProcessTrusted(), !Task.isCancelled else { return }
                let point = AgentPointerElement.pointerLocation()
                let info = await Task.detached(priority: .userInitiated) {
                    AgentPointerElement.capture(at: point)
                }.value
                guard !Task.isCancelled else { return }
                store.updatePointerElement(info?.promptDescription)
            },
            Task { @MainActor in
                guard CGPreflightScreenCaptureAccess(), !Task.isCancelled else { return }
                let screenCaptureService = ScreenCaptureService()
                let screenText = await screenCaptureService.captureAndExtractText()
                guard !Task.isCancelled else { return }
                store.updateScreenText(screenText)
            },
        ]
    }
}
