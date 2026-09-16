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
    static let didApplyDefaultKey = "didApplyDefaultLaunchAtLogin"

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
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didApplyDefaultKey) else { return }
        defaults.set(true, forKey: Self.didApplyDefaultKey)

        logger.info("Registering launch at login for the first run on this machine.")
        setEnabled(true)
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
            }
        }

        isUpdating = false
        updateTask = nil
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
