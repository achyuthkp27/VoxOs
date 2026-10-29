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

    // MARK: Choosing

    /// The devices the Music page's Output list offers: every one with output channels, less the
    /// virtual and aggregate plumbing apps make for themselves. No permission is needed.
    static func outputDevices() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.filter(hasOutput).compactMap(device).filter { isWorthANotice(transport: $0.transport) }
    }

    private static func hasOutput(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    /// Makes `id` the Mac's sound output. Core Audio answers success for a write it refuses, so the
    /// answer is whether the default output reads back as `id`.
    @discardableResult
    static func makeDefaultOutput(_ id: AudioObjectID) -> Bool {
        var address = defaultOutputAddress
        var device = id
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, size, &device)
        return defaultOutput() == id
    }

    /// The Output list's glyph: the laptop for its own speakers, as a picker names places.
    static func pickerSymbol(for device: Device) -> String {
        if device.transport == kAudioDeviceTransportTypeBuiltIn,
            !device.name.localizedCaseInsensitiveContains("headphone")
        {
            return "laptopcomputer"
        }
        return symbol(for: device)
    }
}
