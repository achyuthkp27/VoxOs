import AppKit
import SwiftData
import SwiftUI

class MenuBarManager: ObservableObject {
    @Published var isMenuBarOnly: Bool {
        didSet {
            UserDefaults.standard.set(isMenuBarOnly, forKey: MenuBarOnlyPreference.key)
            applyActivationPolicy()
        }
    }

    private var modelContainer: ModelContainer?
    private var engine: VoxOSEngine?
    private var defaultsObserver: NSObjectProtocol?
    private var lastKnownMenuBarOnlyActive: Bool
    private var configuredActivationPolicy: NSApplication.ActivationPolicy {
        MenuBarOnlyPreference.isActive ? .accessory : .regular
    }

    init() {
        self.isMenuBarOnly = MenuBarOnlyPreference.isEnabled
        self.lastKnownMenuBarOnlyActive = MenuBarOnlyPreference.isActive
        applyActivationPolicy()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(userFacingWindowWillClose),
            name: NSWindow.willCloseNotification,
            object: nil
        )

        // Finishing (or re-running) onboarding flips the *effective* menu-bar-only state without
        // touching `IsMenuBarOnly`, so the policy has to be reconciled when that happens too.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            self?.reconcileIfEffectiveStateChanged()
        }
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        NotificationCenter.default.removeObserver(self)
    }

    private func reconcileIfEffectiveStateChanged() {
        let isActive = MenuBarOnlyPreference.isActive
        guard isActive != lastKnownMenuBarOnlyActive else { return }
        lastKnownMenuBarOnlyActive = isActive

        // Reconcile only — never hide a window out from under the user here. A window that is
        // still open keeps the app `.regular`; the Dock icon drops when they close it.
        AppPresentationPolicy.reconcileActivationPolicy()
    }

    @objc private func userFacingWindowWillClose(_ notification: Notification) {
        guard MenuBarOnlyPreference.isActive,
            let window = notification.object as? NSWindow,
            window.level == .normal,
            window.styleMask.contains(.titled)
        else {
            return
        }

        AppPresentationPolicy.restoreAccessoryIfNeededAfterUserFacingWindowClosed(excluding: window)
    }

    func configure(modelContainer: ModelContainer, engine: VoxOSEngine) {
        self.modelContainer = modelContainer
        self.engine = engine
        Task { @MainActor in
            EdgeHistoryWindowManager.shared.configure(modelContainer: modelContainer, engine: engine)
            SystemAudioCaptureController.shared.configure(engine: engine)
            AgentEnvironment.engine = engine
        }
    }

    func toggleMenuBarOnly() {
        isMenuBarOnly.toggle()
    }

    func applyActivationPolicy() {
        let applyPolicy = { [weak self] in
            guard let self else { return }

            NSApplication.shared.setActivationPolicy(self.configuredActivationPolicy)
            self.lastKnownMenuBarOnlyActive = MenuBarOnlyPreference.isActive

            if MenuBarOnlyPreference.isActive {
                WindowManager.shared.hideMainWindow()
            }
        }

        if Thread.isMainThread {
            applyPolicy()
        } else {
            DispatchQueue.main.async(execute: applyPolicy)
        }
    }

    func activateForPresentedWindow() {
        let activate = {
            AppPresentationPolicy.activateForUserFacingWindow()
        }

        if Thread.isMainThread {
            activate()
        } else {
            DispatchQueue.main.async(execute: activate)
        }
    }

    func openHistoryWindow() {
        guard let modelContainer = modelContainer,
            let engine = engine
        else {
            return
        }

        let openWindow = { [weak self] in
            self?.activateForPresentedWindow()

            HistoryWindowController.shared.showHistoryWindow(
                modelContainer: modelContainer,
                engine: engine
            )
        }

        if Thread.isMainThread {
            openWindow()
        } else {
            DispatchQueue.main.async(execute: openWindow)
        }
    }
}
