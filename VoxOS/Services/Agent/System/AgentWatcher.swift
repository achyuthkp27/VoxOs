import Foundation

/// Ambient screen triggers — "tell me when you see X". Polls the screen with OCR on an
/// interval and raises a notification when the text appears. Runs in the background after
/// the tool call returns, so the agent's turn ends immediately.
@MainActor
enum AgentWatcher {

    struct Watch {
        let id: String
        let text: String
        let startedAt: Date
        let timeout: TimeInterval
        var task: Task<Void, Never>?
    }

    private static var watches: [String: Watch] = [:]
    static let pollSeconds: TimeInterval = 2.5
    static let maxTimeoutSeconds: TimeInterval = 60 * 60

    static func watch(forText text: String, timeoutSeconds: Int) -> [String: Any] {
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return ["error": "text is required"] }
        let timeout = min(maxTimeoutSeconds, max(10, TimeInterval(timeoutSeconds)))
        let id = "w\(Int(Date().timeIntervalSince1970) % 100_000)"

        var watch = Watch(id: id, text: target, startedAt: Date(), timeout: timeout, task: nil)
        watch.task = Task { @MainActor in
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline, !Task.isCancelled {
                if let shot = await AgentScreen.capture() {
                    let matches = await AgentScreen.recognizeText(in: shot, accurate: false)
                    if matches.contains(where: { $0.text.lowercased().contains(target.lowercased()) }) {
                        NotificationManager.shared.showNotification(
                            title: String(format: String(localized: "“%@” is on screen"), target),
                            type: .info,
                            duration: 6)
                        watches[id] = nil
                        return
                    }
                }
                try? await Task.sleep(nanoseconds: UInt64(pollSeconds * 1_000_000_000))
            }
            watches[id] = nil
        }
        watches[id] = watch
        return ["ok": true, "watch_id": id, "text": target, "timeout_seconds": Int(timeout), "note": "Watching the screen in the background. The user will be notified when the text appears."]
    }

    /// "Tell me when you hear X" — needs the system-audio rolling buffer to be on.
    static func watchAudio(forText text: String, timeoutSeconds: Int) -> [String: Any] {
        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return ["error": "text is required"] }
        let controller = SystemAudioCaptureController.shared
        guard controller.isBufferRunning else {
            return ["error": "system audio buffering is off; the user can enable “Keep Recent System Audio” in Settings → System Audio"]
        }
        let timeout = min(maxTimeoutSeconds, max(10, TimeInterval(timeoutSeconds)))
        let id = "a\(Int(Date().timeIntervalSince1970) % 100_000)"
        var watch = Watch(id: id, text: target, startedAt: Date(), timeout: timeout, task: nil)
        watch.task = Task { @MainActor in
            let deadline = Date().addingTimeInterval(timeout)
            let window: Double = 10
            while Date() < deadline, !Task.isCancelled {
                let result = await controller.agentRecall(seconds: window)
                if let transcript = result["transcript"] as? String, transcript.lowercased().contains(target.lowercased()) {
                    NotificationManager.shared.showNotification(
                        title: String(format: String(localized: "Heard “%@”"), target), type: .info, duration: 6)
                    watches[id] = nil
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64((window - 2) * 1_000_000_000))
            }
            watches[id] = nil
        }
        watches[id] = watch
        return ["ok": true, "watch_id": id, "text": target, "timeout_seconds": Int(timeout), "note": "Listening to system audio in the background; the user will be notified when it is heard."]
    }

    static func list() -> [String: Any] {
        ["watches": watches.values.map { ["id": $0.id, "text": $0.text, "seconds_left": Int($0.timeout - Date().timeIntervalSince($0.startedAt))] }]
    }

    static func cancel(id: String?) -> [String: Any] {
        if let id, let watch = watches[id] {
            watch.task?.cancel()
            watches[id] = nil
            return ["ok": true, "cancelled": id]
        }
        let count = watches.count
        watches.values.forEach { $0.task?.cancel() }
        watches.removeAll()
        return ["ok": true, "cancelled_all": count]
    }
}
