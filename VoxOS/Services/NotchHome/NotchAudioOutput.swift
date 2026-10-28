import CoreAudio
import Foundation

/// Tells when the Mac's sound output moves to another device (AirPods taking over, a display,
/// headphones in the jack), for a short notice in the notch. Core Audio calls back on a change;
/// nothing is polled.
final class NotchAudioOutput: @unchecked Sendable {
    struct Device: Equatable {
        let id: AudioObjectID
        let name: String
        let transport: UInt32

        var isBluetooth: Bool {
            transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
        }
    }

    /// A switch fires more than once; the device the output settles on this long after counts.
    static let settle: TimeInterval = 0.5

    private let queue = DispatchQueue(label: "com.achyuthkp.voxos.audio-output")
    private var listener: AudioObjectPropertyListenerBlock?
    private var current: AudioObjectID = kAudioObjectUnknown
    private var pending: DispatchWorkItem?
    private var onChange: (@Sendable (Device) -> Void)?

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    func start(onChange: @escaping @Sendable (Device) -> Void) {
        queue.async { [self] in
            guard listener == nil else { return }
            self.onChange = onChange
            current = Self.defaultOutput()
            var address = Self.defaultOutputAddress
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.changed() }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
                == noErr
            {
                listener = block
            }
        }
    }

    func stop() {
        queue.async { [self] in
            pending?.cancel()
            pending = nil
            onChange = nil
            guard let listener else { return }
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
            self.listener = nil
        }
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let id = Self.defaultOutput()
            guard id != kAudioObjectUnknown, id != self.current else { return }
            self.current = id
            guard let device = Self.device(id), Self.isWorthANotice(transport: device.transport) else { return }
            self.onChange?(device)
        }
        pending = work
        queue.asyncAfter(deadline: .now() + Self.settle, execute: work)
    }

    /// Virtual devices (a meeting app's own, a recorder's loopback) and aggregates are plumbing
    /// that apps switch on their own, not a place the user sent the sound.
    static func isWorthANotice(transport: UInt32) -> Bool {
        transport != kAudioDeviceTransportTypeVirtual && transport != kAudioDeviceTransportTypeAggregate
            && transport != kAudioDeviceTransportTypeAutoAggregate && transport != 0
    }

    static func symbol(for device: Device) -> String {
        switch device.transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            // The audio class, so AirPods get their own icon and anything else headphones.
            return NotchDeviceAlerts.symbol(name: device.name, majorClass: 0x04, minorClass: 0)
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "tv"
        case kAudioDeviceTransportTypeBuiltIn:
            return device.name.localizedCaseInsensitiveContains("headphone") ? "headphones" : "speaker.wave.2.fill"
        default:
            return "hifispeaker.fill"
        }
    }

    static func defaultOutput() -> AudioObjectID {
        var address = defaultOutputAddress
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr ? id : AudioObjectID(kAudioObjectUnknown)
    }

    static func device(_ id: AudioObjectID) -> Device? {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &size, &name) == noErr,
            let text = name?.takeRetainedValue() as String?, !text.isEmpty
        else { return nil }
        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &size, &transport)
        return Device(id: id, name: text, transport: transport)
    }
}
