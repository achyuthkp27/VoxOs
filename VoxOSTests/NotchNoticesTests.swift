import CoreAudio
import Foundation
import IOKit.ps
import Testing

@testable import VoxOS

/// What the notch says about the Mac itself: the power adapter and battery, where the sound
/// goes, a microphone or camera in use, and the next meeting.
@Suite
@MainActor
struct NotchNoticesTests {

    // MARK: Battery

    private static func battery(_ percent: Int, adapter: Bool, charging: Bool = false) -> PowerState.Battery {
        PowerState.Battery(percent: percent, charging: charging, onAdapter: adapter)
    }

    @Test func theAdapterGoingInOrOutIsSaid() {
        let plugged = NotchDeviceAlerts.batteryNotice(
            from: Self.battery(54, adapter: false), to: Self.battery(54, adapter: true, charging: true))
        #expect(plugged?.key == "power-on")
        #expect(plugged?.detail == "54%")
        let unplugged = NotchDeviceAlerts.batteryNotice(
            from: Self.battery(80, adapter: true), to: Self.battery(80, adapter: false))
        #expect(unplugged?.key == "power-off")
        #expect(unplugged?.symbol == "battery.75percent")
        #expect(
            NotchDeviceAlerts.batteryNotice(
                from: Self.battery(60, adapter: false), to: Self.battery(59, adapter: false))
                == nil, "a percent on its own is not news")
        #expect(NotchDeviceAlerts.batteryNotice(from: nil, to: Self.battery(50, adapter: false)) == nil)
    }

    @Test func aLowBatteryIsSaidOncePerLevelAndOnlyOnBattery() {
        let low = NotchDeviceAlerts.batteryNotice(
            from: Self.battery(21, adapter: false), to: Self.battery(20, adapter: false))
        #expect(low?.key == "battery-low-20")
        #expect(
            NotchDeviceAlerts.batteryNotice(
                from: Self.battery(20, adapter: false), to: Self.battery(19, adapter: false))
                == nil, "already said at 20")
        let jump = NotchDeviceAlerts.batteryNotice(
            from: Self.battery(12, adapter: false), to: Self.battery(4, adapter: false))
        #expect(jump?.key == "battery-low-5", "the lowest level crossed")
        #expect(
            NotchDeviceAlerts.batteryNotice(from: Self.battery(21, adapter: true), to: Self.battery(20, adapter: true))
                == nil, "charging up or holding is not low")
    }

    @Test func batteryLevelsReadFromThePowerSource() {
        let battery = PowerState.battery(from: [
            kIOPSCurrentCapacityKey: 45, kIOPSMaxCapacityKey: 90, kIOPSIsChargingKey: true,
            kIOPSPowerSourceStateKey: kIOPSACPowerValue,
        ])
        #expect(battery == PowerState.Battery(percent: 50, charging: true, onAdapter: true))
        #expect(PowerState.battery(from: [kIOPSCurrentCapacityKey: 45]) == nil)
        #expect(NotchDeviceAlerts.batterySymbol(3) == "battery.0percent")
        #expect(NotchDeviceAlerts.batterySymbol(100) == "battery.100percent")
    }

    // MARK: Sound output

    @Test func outputIconsComeFromHowTheDeviceIsConnected() {
        func symbol(_ name: String, _ transport: UInt32) -> String {
            NotchAudioOutput.symbol(for: .init(id: 1, name: name, transport: transport))
        }
        #expect(symbol("Someone's AirPods Pro", kAudioDeviceTransportTypeBluetooth) == "airpodspro")
        #expect(symbol("Desk Headset", kAudioDeviceTransportTypeBluetoothLE) == "headphones")
        #expect(symbol("Living Room", kAudioDeviceTransportTypeAirPlay) == "airplayaudio")
        #expect(symbol("Display", kAudioDeviceTransportTypeHDMI) == "tv")
        #expect(symbol("External Headphones", kAudioDeviceTransportTypeBuiltIn) == "headphones")
        #expect(symbol("Speakers", kAudioDeviceTransportTypeBuiltIn) == "speaker.wave.2.fill")
        #expect(symbol("Interface", kAudioDeviceTransportTypeUSB) == "hifispeaker.fill")
    }

    @Test func plumbingDevicesAreNotAnnounced() {
        #expect(NotchAudioOutput.isWorthANotice(transport: kAudioDeviceTransportTypeBluetooth))
        #expect(NotchAudioOutput.isWorthANotice(transport: kAudioDeviceTransportTypeBuiltIn))
        #expect(!NotchAudioOutput.isWorthANotice(transport: kAudioDeviceTransportTypeVirtual))
        #expect(!NotchAudioOutput.isWorthANotice(transport: kAudioDeviceTransportTypeAggregate))
    }
}
