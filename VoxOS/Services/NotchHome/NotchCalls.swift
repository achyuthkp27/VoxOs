import Combine
import Foundation

/// A call is on while another app uses the microphone or a camera (`NotchPrivacy`, which leaves
/// VoxOS's own dictation out). When one begins, a running pomodoro waits and the volume preset
/// chosen for calls is applied; when it ends, the pomodoro goes on and the levels from before
/// come back.
///
/// A call counts once it has lasted a few seconds, and is over once the microphone and cameras
/// have been free a few seconds, so a quick check of the microphone changes nothing.
@MainActor
final class NotchCalls {
    static let shared = NotchCalls()

    nonisolated static let settle: TimeInterval = 4

    private var watch: AnyCancellable?
    private var pending: Task<Void, Never>?
    private var inCall = false
    /// The levels from before the call's preset, to go back to.
    private var beforeCall: NotchMixer.Preset?

    private init() {}

    /// The preset to apply during calls, when one is chosen and still exists.
    static var callPreset: NotchMixer.Preset? {
        guard NotchMixer.isEnabled, let id = UserDefaults.standard.string(forKey: DefaultsKeys.notchCallPreset),
            !id.isEmpty
        else { return nil }
        return NotchMixer.shared.presets.first { $0.id.uuidString == id }
    }

    /// Whether anything waits on calls, so the microphone and cameras need watching.
    static var isWanted: Bool { NotchTimers.shared.options.pausesForCalls || callPreset != nil }

    /// Follows `NotchPrivacy` while wanted. The state at the start is where things stand, not a
    /// call beginning: a pomodoro started during a call is not paused by it.
    func setActive(_ active: Bool) {
        guard active != (watch != nil) else { return }
        pending?.cancel()
        pending = nil
        guard active else {
            watch = nil
            if inCall { ended() }
            inCall = false
            return
        }
        inCall = NotchPrivacy.shared.state.isActive
        watch = NotchPrivacy.shared.$state.map(\.isActive).removeDuplicates().dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] active in self?.changed(active) }
    }

    private func changed(_ active: Bool) {
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.settle))
            guard !Task.isCancelled, let self, active != self.inCall else { return }
            self.inCall = active
            if active { self.began() } else { self.ended() }
        }
    }

    private func began() {
        ActivityTrail.mark("notch call began")
        NotchTimers.shared.callStarted()
        if let preset = Self.callPreset {
            beforeCall = NotchMixer.shared.current
            NotchMixer.shared.applyPreset(preset)
        }
    }

    private func ended() {
        ActivityTrail.mark("notch call ended")
        NotchTimers.shared.callEnded()
        if let beforeCall {
            NotchMixer.shared.applyPreset(beforeCall)
            self.beforeCall = nil
        }
    }
}
