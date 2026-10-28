import Combine
import Foundation
import IOKit.pwr_mgt

/// Keeps the display (and so the Mac) awake while on, from a button in the open card: a power
/// assertion, which costs nothing by itself. It lets go on its own when the battery runs low on
/// battery power, so the Mac is never kept up until it dies.
@MainActor
final class NotchKeepAwake: ObservableObject {
    static let shared = NotchKeepAwake()

    /// On battery at or below this, keeping awake stops.
    nonisolated static let lowBattery = 10

    @Published private(set) var isOn = false

    private var assertion: IOPMAssertionID = 0
    private var batteryWatch: AnyCancellable?

    private init() {}

    func toggle() {
        if isOn { stop() } else { start() }
    }

    func start() {
        guard !isOn else { return }
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "VoxOS: kept awake from the notch" as CFString, &id)
        guard status == kIOReturnSuccess else { return }
        assertion = id
        isOn = true
        ActivityTrail.mark("keep awake on")
        batteryWatch = PowerState.shared.$battery.receive(on: RunLoop.main).sink { [weak self] battery in
            if let battery, Self.shouldLetGo(battery) { self?.stop() }
        }
    }

    func stop() {
        guard isOn else { return }
        IOPMAssertionRelease(assertion)
        assertion = 0
        isOn = false
        batteryWatch = nil
        ActivityTrail.mark("keep awake off")
    }

    nonisolated static func shouldLetGo(_ battery: PowerState.Battery) -> Bool {
        !battery.onAdapter && battery.percent <= lowBattery
    }
}
