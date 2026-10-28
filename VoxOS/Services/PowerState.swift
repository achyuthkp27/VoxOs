import AppKit
import Combine
import IOKit.ps

/// What the Mac's power and displays are doing, for work that should rest when the Mac runs on
/// battery, is in Low Power Mode, or has nobody looking at the screen.
///
/// Everything here arrives as a notification; nothing is polled.
@MainActor
final class PowerState: ObservableObject {
    static let shared = PowerState()

    /// Running on the battery, not an adapter. Always false on a Mac without one.
    @Published private(set) var onBattery = PowerState.readOnBattery()
    @Published private(set) var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// The displays sleep or the screen is locked: nothing drawn is seen.
    @Published private(set) var isAway = false

    private var displaysAsleep = false {
        didSet { updateAway() }
    }
    private var locked = false {
        didSet { updateAway() }
    }
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var powerSource: CFRunLoopSource?

    private init() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displaysAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displaysAsleep = false }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false }
        observe(NotificationCenter.default, Notification.Name.NSProcessInfoPowerStateDidChange) {
            $0.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        }

        // Called on the main run loop whenever a power source changes (adapter in or out).
        let source = IOPSNotificationCreateRunLoopSource(
            { _ in
                Task { @MainActor in PowerState.shared.refreshPowerSource() }
            }, nil)?.takeRetainedValue()
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
    }

    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name, _ apply: @escaping @MainActor (PowerState) -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                apply(self)
            }
        }
        observers.append((center, token))
    }

    private func refreshPowerSource() {
        let battery = Self.readOnBattery()
        if battery != onBattery { onBattery = battery }
    }

    private func updateAway() {
        let away = displaysAsleep || locked
        if away != isAway { isAway = away }
    }

    nonisolated static func readOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue()
        else { return false }
        return (type as String) == kIOPSBatteryPowerValue
    }
}
