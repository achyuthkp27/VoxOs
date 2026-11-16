import Foundation
import IOKit.ps
import Testing

@testable import VoxOS

/// Charging said in the notch: plugging in, the time to full, and charging done.
@Suite
@MainActor
struct NotchChargingTests {

    @Test func pluggingInWhileChargingSaysChargingAndTheTimeOnceKnown() {
        let off = PowerState.Battery(percent: 40, charging: false, onAdapter: false)
        let on = PowerState.Battery(percent: 40, charging: true, onAdapter: true, minutesToFull: 85)
        let notice = NotchDeviceAlerts.batteryNotice(from: off, to: on)
        #expect(notice?.title == "Charging")
        #expect(notice?.detail == "40% · 1:25 to full")
        let unknown = PowerState.Battery(percent: 40, charging: true, onAdapter: true)
        #expect(NotchDeviceAlerts.batteryNotice(from: off, to: unknown)?.detail == "40%")
    }

    @Test func chargingStoppingOnTheAdapterIsSaidAsCharged() {
        let charging = PowerState.Battery(percent: 99, charging: true, onAdapter: true)
        let full = PowerState.Battery(percent: 100, charging: false, onAdapter: true)
        #expect(NotchDeviceAlerts.batteryNotice(from: charging, to: full)?.key == "charged")
        // Unplugging is said as going on battery, not as charged.
        let unplugged = PowerState.Battery(percent: 99, charging: false, onAdapter: false)
        #expect(NotchDeviceAlerts.batteryNotice(from: charging, to: unplugged)?.key == "power-off")
    }

    @Test func theTimeToFullIsReadAndAnUnknownOneIsLeftOut() {
        let base: [String: Any] = [
            kIOPSCurrentCapacityKey: 50, kIOPSMaxCapacityKey: 100, kIOPSIsChargingKey: true,
            kIOPSPowerSourceStateKey: kIOPSACPowerValue,
        ]
        var known = base
        known[kIOPSTimeToFullChargeKey] = 42
        #expect(PowerState.battery(from: known)?.minutesToFull == 42)
        var unknown = base
        unknown[kIOPSTimeToFullChargeKey] = -1
        #expect(PowerState.battery(from: unknown)?.minutesToFull == nil)
    }
}
