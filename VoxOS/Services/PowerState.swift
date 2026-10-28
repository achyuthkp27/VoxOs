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

    struct Battery: Equatable {
        let percent: Int
        let charging: Bool
        /// On the adapter, whether or not it is charging (it holds at 80% to spare the battery).
        let onAdapter: Bool
    }

    /// Running on the battery, not an adapter. Always false on a Mac without one.
    @Published private(set) var onBattery = PowerState.readOnBattery()
    /// The internal battery; nil on a Mac without one. Changes about once a percent.
    @Published private(set) var battery = PowerState.readBattery()
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
        let onBattery = Self.readOnBattery()
        if onBattery != self.onBattery { self.onBattery = onBattery }
        let battery = Self.readBattery()
        if battery != self.battery { self.battery = battery }
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

    nonisolated static func readBattery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            return battery(from: description)
        }
        return nil
    }

    /// From one power source's description (IOPowerSources keys).
    nonisolated static func battery(from description: [String: Any]) -> Battery? {
        guard let current = description[kIOPSCurrentCapacityKey] as? Int,
            let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0
        else { return nil }
        return Battery(
            percent: min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded()))),
            charging: description[kIOPSIsChargingKey] as? Bool ?? false,
            onAdapter: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
    }
}
