import AppKit
import Combine
import Foundation
import ServiceManagement
import os

@MainActor
final class LaunchAtLoginManager: ObservableObject {
    static let shared = LaunchAtLoginManager()

    @Published private(set) var isEnabled = false
    @Published private(set) var isUpdating = false

    /// One-shot marker for the first-launch registration below.
    nonisolated static let didApplyDefaultKey = "didApplyDefaultLaunchAtLogin"

    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "LaunchAtLogin")
    private var isRefreshing = false
    private var operationGeneration = 0
    private var pendingEnabledState: Bool?
    private var updateTask: Task<Void, Never>?

    private init() {
        refresh()
    }

    func refresh() {
        guard !isRefreshing, !isUpdating else { return }

        isRefreshing = true
        let generation = operationGeneration

        Task {
            let enabled = await Self.readEnabledStatus()
            isRefreshing = false

            guard generation == operationGeneration else { return }
            isEnabled = enabled
        }
    }

    /// Turns launch at login on the first time VoxOS runs on a machine. It is a background app
    /// driven by fn and ⌃⌃, so it has to come back after a restart to be of any use, and a fresh
    /// install should not need the user to go find the toggle.
    ///
    /// The one-shot flag is the whole point: it runs once per machine, so switching it off later
    /// sticks instead of being re-enabled on the next launch.
    func enableByDefaultIfNeeded() {
        // `SMAppService.mainApp` registers whichever bundle is running, and the test host and
        // every build product share this bundle identifier. Registering one of those points the
        // login item at a throwaway path that fails to launch, so only the installed copy may
        // arm this automatically. An explicit toggle still works from anywhere.
        guard Self.isInstalledCopy else {
            logger.info("Skipping the launch at login default: not running from /Applications.")
            return
        }

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didApplyDefaultKey) else { return }
        defaults.set(true, forKey: Self.didApplyDefaultKey)

        logger.info("Registering launch at login for the first run on this machine.")
        setEnabled(true)
    }

    /// True only for a copy living in an Applications folder, which is the only place a login
    /// item can point at and still be there next login.
    private static var isInstalledCopy: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return path.hasPrefix("/Applications/") || path.contains("/Applications/")
    }

    func setEnabled(_ enabled: Bool) {
        operationGeneration += 1
        isEnabled = enabled
        pendingEnabledState = enabled

        guard updateTask == nil else { return }

        isUpdating = true
        updateTask = Task { [weak self] in
            await self?.applyPendingEnabledStates()
        }
    }

    func currentEnabledStatus() async -> Bool {
        operationGeneration += 1

        while true {
            let generation = operationGeneration

            if let updateTask {
                await updateTask.value
                continue
            }

            let enabled = await Self.readEnabledStatus()
            guard generation == operationGeneration, updateTask == nil else {
                continue
            }

            isEnabled = enabled
            return enabled
        }
    }

    private func applyPendingEnabledStates() async {
        while let enabled = pendingEnabledState {
            pendingEnabledState = nil
            let result = await Self.updateRegistration(enabled: enabled)

            if pendingEnabledState == nil {
                isEnabled = result.isEnabled
            }

            if let errorDescription = result.errorDescription {
                logger.error(
                    "Failed to \(enabled ? "enable" : "disable", privacy: .public) launch at login: \(errorDescription, privacy: .public)"
                )
                reportFailure(whileEnabling: enabled)
            }
        }

        isUpdating = false
        updateTask = nil
    }

    /// A failed registration used to be log-only: the toggle snapped back to the real status and
    /// said nothing. That is worse now that `enableByDefaultIfNeeded` runs unattended on first
    /// launch, where the difference is whether VoxOS comes back after a restart at all.
    private func reportFailure(whileEnabling enabled: Bool) {
        let title =
            enabled
            ? String(localized: "VoxOS could not add itself to your login items")
            : String(localized: "VoxOS could not remove itself from your login items")

        NotificationManager.shared.showNotification(
            title: title,
            type: .error,
            duration: 7.0,
            actionButton: (
                String(localized: "Open Settings"),
                {
                    if let url = URL(
                        string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
                    {
                        NSWorkspace.shared.open(url)
                    }
                }
            )
        )
    }

    private nonisolated static func readEnabledStatus() async -> Bool {
        await Task.detached(priority: .utility) {
            SMAppService.mainApp.status == .enabled
        }.value
    }

    private nonisolated static func updateRegistration(enabled: Bool) async -> UpdateResult {
        await Task.detached(priority: .utility) {
            let service = SMAppService.mainApp

            do {
                if enabled {
                    if service.status != .enabled {
                        try service.register()
                    }
                } else if service.status != .notRegistered {
                    try service.unregister()
                }
            } catch {
                return UpdateResult(
                    isEnabled: service.status == .enabled,
                    errorDescription: error.localizedDescription
                )
            }

            return UpdateResult(
                isEnabled: service.status == .enabled,
                errorDescription: nil
            )
        }.value
    }

    private struct UpdateResult: Sendable {
        let isEnabled: Bool
        let errorDescription: String?
    }
}
