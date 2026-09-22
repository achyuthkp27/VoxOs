import Foundation
import os

@MainActor
class ModeShortcutManager {
    private static let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "Shortcuts")
    private let modeProvider: @MainActor () -> RecordingShortcutManager.Mode
    private let shortcutModeHandler: RecordingShortcutModeHandler
    private var shortcutChangeObserver: NSObjectProtocol?
    private var pendingRefresh: Task<Void, Never>?

    init(
        modeProvider: @escaping @MainActor () -> RecordingShortcutManager.Mode,
        shortcutModeHandler: RecordingShortcutModeHandler
    ) {
        self.modeProvider = modeProvider
        self.shortcutModeHandler = shortcutModeHandler

        refreshModeShortcuts()

        shortcutChangeObserver = NotificationCenter.default.addObserver(
            forName: ShortcutStore.shortcutDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let action = notification.object as? ShortcutAction,
                case .mode = action
            else {
                return
            }

            self?.scheduleRefresh()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(modeShortcutAvailabilityDidChange),
            name: .modeShortcutAvailabilityDidChange,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let shortcutChangeObserver {
            NotificationCenter.default.removeObserver(shortcutChangeObserver)
        }
        // Not actor-isolated, and `assumeIsolated` would trap if the last reference is dropped
        // off the main thread.
        ShortcutMonitor.shared.unregister(owner: .mode)
    }

    @objc private func modeShortcutAvailabilityDidChange() {
        Task { @MainActor in
            scheduleRefresh()
        }
    }

    /// Rebuilding tears down a system-wide event tap and spawns a new thread, and a single user
    /// action can post several shortcut notifications. Collapse a burst into one rebuild on the
    /// next main-loop turn rather than doing that work once per notification.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.pendingRefresh = nil
            self.refreshModeShortcuts()
        }
    }

    private func refreshModeShortcuts() {
        let shortcuts = ModeManager.shared.enabledConfigurations.reduce(into: [ShortcutAction: Shortcut]()) {
            result, config in
            let action = ShortcutAction.mode(config.id)
            if let shortcut = ShortcutStore.shortcut(for: action) {
                result[action] = shortcut
            }
        }

        Self.logger.notice(
            "mode shortcuts registered: \(shortcuts.map { "\($0.key.storageName)=\($0.value.displayString)" }.sorted().joined(separator: ", "), privacy: .public)"
        )

        ShortcutMonitor.shared.register(
            owner: .mode,
            shortcuts: shortcuts,
            interruptibleActions: Set(shortcuts.keys),
            onKeyDown: { [weak self] action, eventTime in
                Task { @MainActor in
                    Self.logger.notice("mode shortcut down: \(action.storageName, privacy: .public)")
                    guard let self,
                        let modeId = self.modeId(for: action)
                    else {
                        return
                    }

                    await self.shortcutModeHandler.handleKeyDown(
                        action: action,
                        eventTime: eventTime,
                        mode: self.modeProvider(),
                        modeId: modeId
                    )
                }
            },
            onKeyUp: { [weak self] action, eventTime in
                Task { @MainActor in
                    Self.logger.notice("mode shortcut up: \(action.storageName, privacy: .public)")
                    guard let self,
                        case .mode(let modeId) = action
                    else {
                        return
                    }

                    await self.shortcutModeHandler.handleKeyUp(
                        action: action,
                        eventTime: eventTime,
                        mode: self.modeProvider(),
                        modeId: modeId
                    )
                }
            },
            onShortcutInterrupted: { [weak self] action, _ in
                Task { @MainActor in
                    guard let self, case .mode = action else { return }
                    await self.shortcutModeHandler.handleInterruption(action: action)
                }
            }
        )
    }

    private func modeId(for action: ShortcutAction) -> UUID? {
        guard case .mode(let modeId) = action,
            let config = ModeManager.shared.getConfiguration(with: modeId),
            config.isEnabled,
            ShortcutStore.shortcut(for: .mode(config.id)) != nil
        else {
            return nil
        }

        return modeId
    }
}
