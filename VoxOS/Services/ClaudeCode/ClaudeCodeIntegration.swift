import Combine
import Foundation
import os

/// The Claude Code switch in Settings: installs or removes the hooks, starts or stops the bridge,
/// and says what state both are in.
///
/// Off by default, because turning it on edits ~/.claude/settings.json. Turning it off takes the
/// hooks out again, so nothing is left pointing at a port that no longer answers.
@MainActor
final class ClaudeCodeIntegration: ObservableObject {
    static let shared = ClaudeCodeIntegration()

    @Published private(set) var bridgeState: ClaudeCodeBridge.State = .stopped
    @Published private(set) var installState: ClaudeCodeHooks.InstallState = .notInstalled
    /// The last install, removal or read that failed, in words for Settings.
    @Published private(set) var problem: String?
    /// The one-time offer to turn the integration on is in the notch.
    @Published private(set) var isOffering = false

    private let bridge: ClaudeCodeBridge
    private let settingsURL: URL
    private var expiryTimer: Timer?
    private var expiryInterval: TimeInterval?
    private var activityWatch: AnyCancellable?
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "ClaudeCodeIntegration")

    init(bridge: ClaudeCodeBridge = .shared, settingsURL: URL = ClaudeCodeHooks.userSettingsURL) {
        self.bridge = bridge
        self.settingsURL = settingsURL
        bridge.onStateChange = { [weak self] state in self?.bridgeState = state }
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.claudeCodeEnabled) }
    static var approvalsEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.claudeCodeApprovalsEnabled) }
    static var statusEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.claudeCodeStatusEnabled) }
    static var quietInTerminal: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.claudeCodeQuietInTerminal) }
    static var repliesEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.claudeCodeRepliesEnabled) }
    static var usageEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.claudeCodeUsageEnabled) }
    static var codexEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.codexNotifyEnabled) }
    static var geminiEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.geminiHooksEnabled) }
    static var speaksReplies: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.claudeCodeSpeaksReplies) }

    var port: UInt16 { ClaudeCodeBridge.defaultPort }

    /// At launch: listen if the user turned the integration on. The hooks are not rewritten here;
    /// if the user removed them by hand, Settings shows that and offers to put them back.
    func startIfEnabled() {
        guard !ProcessIdentity.isTestHost else { return }
        guard Self.isEnabled else { return offerIfAppropriate() }
        startBridge()
        refreshInstallState()
    }

    /// Asked once, on a Mac where Claude Code is installed, so a new install does not depend on
    /// the user finding the switch in Settings. Never before onboarding is finished, and never again
    /// once answered either way; Settings keeps the switch.
    static func shouldOffer(enabled: Bool, answered: Bool, onboarded: Bool, claudeCodeInstalled: Bool) -> Bool {
        !enabled && !answered && onboarded && claudeCodeInstalled
    }

    /// The CLI creates ~/.claude on its first run.
    static var claudeCodeInstalled: Bool {
        var isDirectory: ObjCBool = false
        let path = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func offerIfAppropriate() {
        let defaults = UserDefaults.standard
        guard
            Self.shouldOffer(
                enabled: Self.isEnabled, answered: defaults.bool(forKey: DefaultsKeys.claudeCodeOfferAnswered),
                onboarded: defaults.bool(forKey: DefaultsKeys.hasCompletedOnboardingV2),
                claudeCodeInstalled: Self.claudeCodeInstalled)
        else { return }
        // A moment after launch, so it does not arrive in the same breath as the menu bar icon.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Self.isEnabled else { return }
            self.isOffering = true
        }
    }

    func answerOffer(turnOn: Bool) {
        UserDefaults.standard.set(true, forKey: DefaultsKeys.claudeCodeOfferAnswered)
        isOffering = false
        if turnOn { setEnabled(true) }
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: DefaultsKeys.claudeCodeEnabled)
        guard !ProcessIdentity.isTestHost else { return }
        if enabled {
            installHooks()
            startBridge()
        } else {
            removeHooks()
            stopBridge()
            // Nothing is left pointing at a bridge that no longer listens.
            if Self.usageEnabled { setUsageEnabled(false) }
            if Self.codexEnabled { setCodexEnabled(false) }
            if Self.geminiEnabled { setGeminiEnabled(false) }
        }
    }

    /// Wraps the status line command (or puts the user's own back) for usage limits and costs.
    func setUsageEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: DefaultsKeys.claudeCodeUsageEnabled)
        guard !ProcessIdentity.isTestHost else { return }
        do {
            if enabled {
                try ClaudeCodeStatusRelay.install(port: port, at: settingsURL)
            } else {
                try ClaudeCodeStatusRelay.uninstall(at: settingsURL)
            }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Adds (or removes) VoxOS's `notify` in Codex's config.
    func setCodexEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: DefaultsKeys.codexNotifyEnabled)
        guard !ProcessIdentity.isTestHost else { return }
        do {
            if enabled { try CodexNotify.install(port: port) } else { try CodexNotify.uninstall() }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Adds (or removes) VoxOS's hooks in Gemini CLI's settings.
    func setGeminiEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: DefaultsKeys.geminiHooksEnabled)
        guard !ProcessIdentity.isTestHost else { return }
        do {
            if enabled { try GeminiHooks.install(port: port) } else { try GeminiHooks.uninstall() }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    func setApprovalsEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: DefaultsKeys.claudeCodeApprovalsEnabled)
        bridge.setApprovalsEnabled(Self.holdsRequests)
        // A request already in the notch goes back to the terminal rather than staying answerable.
        if !enabled { ClaudeCodeActivity.shared.settleAll() }
    }

    func installHooks() {
        do {
            try ClaudeCodeHooks.install(port: port, at: settingsURL)
            problem = nil
            logger.notice("Claude Code hooks installed")
        } catch {
            problem = error.localizedDescription
            logger.error("Claude Code hooks not installed: \(error.localizedDescription, privacy: .public)")
        }
        refreshInstallState()
    }

    func refreshInstallState() {
        do {
            installState = try ClaudeCodeHooks.state(at: settingsURL, port: port)
        } catch {
            problem = error.localizedDescription
        }
    }

    private func removeHooks() {
        do {
            try ClaudeCodeHooks.uninstall(at: settingsURL)
            problem = nil
        } catch {
            problem = error.localizedDescription
            logger.error("Claude Code hooks not removed: \(error.localizedDescription, privacy: .public)")
        }
        refreshInstallState()
    }

    /// Requests are held for the notch only while there is a notch to answer them in.
    private static var holdsRequests: Bool { approvalsEnabled && MasterSwitches.notchEnabled }

    /// The dashboard's notch switch: off, requests go back to the terminal and new ones are not
    /// held; on again, they are.
    func notchSwitchChanged() {
        bridge.setApprovalsEnabled(Self.holdsRequests)
        if !Self.holdsRequests { ClaudeCodeActivity.shared.settleAll() }
    }

    private func startBridge() {
        bridge.start(port: port, approvalsEnabled: Self.holdsRequests)
        let activity = ClaudeCodeActivity.shared
        activityWatch = activity.$prompts.combineLatest(activity.$sessions)
            .receive(on: RunLoop.main)
            .sink { [weak self] prompts, sessions in
                self?.scheduleExpiry(every: Self.expiryInterval(prompts: prompts.count, sessions: sessions.count))
            }
    }

    private func stopBridge() {
        activityWatch = nil
        scheduleExpiry(every: nil)
        bridge.stop()
        ClaudeCodeActivity.shared.settleAll()
    }

    /// How often waiting requests and open sessions are checked. Each check is cheap (a
    /// kill(pid, 0) per session, a child-process listing only while a Bash request waits), but a
    /// timer that never stops wakes the Mac all day. A waiting card is checked twice a second, so
    /// one answered in the terminal, or left by a CLI that was killed, leaves the notch within half
    /// a second; open sessions with nothing waiting only need their CLI noticed gone; with
    /// neither, nothing runs.
    nonisolated static func expiryInterval(prompts: Int, sessions: Int) -> TimeInterval? {
        if prompts > 0 { return 0.5 }
        if sessions > 0 { return 5 }
        return nil
    }

    private func scheduleExpiry(every interval: TimeInterval?) {
        guard interval != expiryInterval else { return }
        expiryInterval = interval
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                ClaudeCodeActivity.shared.expire()
                ClaudeCodeActivity.shared.noticeStartedCommands()
            }
        }
        // Lets macOS fold this wake-up into others nearby.
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }
}
