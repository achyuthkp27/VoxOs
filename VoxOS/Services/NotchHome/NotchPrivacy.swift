import AppKit
import Combine
import CoreAudio
import CoreMediaIO
import Foundation

/// Whether another app is using the microphone or a camera, for a band in the notch with a
/// switch to mute the microphone.
///
/// - Microphone: Core Audio's process objects (macOS 14+) say which processes run input, so
///   VoxOS's own dictation is left out and the app listening can be named and shown. That alone
///   is not enough: Siri's voice trigger (corespeechd) reports running input all day while no
///   microphone runs (measured on macOS 26). So an input device must also be running somewhere,
///   which is when macOS lights its own orange dot, and the voice trigger never counts.
/// - Cameras: CoreMediaIO says whether each one runs somewhere, not for whom.
/// - Mute: the default input's own mute where it has one (the built-in microphone does),
///   otherwise its volume at zero and back. A mute made here is undone when the call ends or
///   VoxOS quits, so the next dictation is never recorded from a muted microphone.
/// Everything arrives through property listeners; nothing is polled.
@MainActor
final class NotchPrivacy: ObservableObject {
    static let shared = NotchPrivacy()

    struct State: Equatable {
        var microphone = false
        var camera = false
        /// The app listening to the microphone, by bundle id, when one can be named.
        var microphoneApp: String?
        var muted = false

        var isActive: Bool { microphone || camera }
        static let idle = State()
    }

    @Published private(set) var state = State.idle

    private let watcher = PrivacyWatcher()
    private var started = false
    private var terminationWatch: NSObjectProtocol?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.notchPrivacyEnabled) }

    private init() {}

    func start() {
        guard !started, !ProcessIdentity.isTestHost else { return }
        started = true
        watcher.start { [weak self] reading in
            Task { @MainActor in self?.update(with: reading) }
        }
        terminationWatch = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.watcher.restoreMuteNow() }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        watcher.stop()
        if let terminationWatch { NotificationCenter.default.removeObserver(terminationWatch) }
        terminationWatch = nil
        state = .idle
    }

    func toggleMute() {
        ActivityTrail.mark("notch microphone \(state.muted ? "unmuted" : "muted")")
        watcher.setMuted(!state.muted)
    }

    private func update(with reading: PrivacyWatcher.Reading) {
        let next = State(
            microphone: !reading.microphonePIDs.isEmpty, camera: reading.camera,
            microphoneApp: Self.app(for: reading), muted: reading.muted)
        if next != state { state = next }
    }

    /// The listening process is often an app's helper (a browser's audio service); the app is
    /// the nearest regular app above it. A system service with none is named by its own id.
    /// Services that report running input without anyone listening: the voice trigger.
    nonisolated static let backgroundListeners: Set<String> = ["com.apple.CoreSpeech"]

    /// The processes really listening: none unless an input device runs, and never VoxOS itself
    /// or a background listener.
    nonisolated static func listeners(
        _ clients: [(pid: pid_t, bundleID: String?)], me: pid_t, inputRunning: Bool
    ) -> [(pid: pid_t, bundleID: String?)] {
        guard inputRunning else { return [] }
        return clients.filter { client in
            client.pid != me && !(client.bundleID.map(backgroundListeners.contains) ?? false)
        }
    }

    private static func app(for reading: PrivacyWatcher.Reading) -> String? {
        for pid in reading.microphonePIDs {
            if let app = ClaudeCodeTerminal.app(hosting: pid),
                let bundleID = NSRunningApplication(processIdentifier: app)?.bundleIdentifier
            {
                return bundleID
            }
        }
        return reading.microphoneBundleIDs.first
    }
}

/// The Core Audio and CoreMediaIO half, on its own queue: listeners call back there.
private final class PrivacyWatcher: @unchecked Sendable {
    struct Reading: Equatable {
        var microphonePIDs: [pid_t] = []
        var microphoneBundleIDs: [String] = []
        var camera = false
        var muted = false
    }

    private let queue = DispatchQueue(label: "com.achyuthkp.voxos.privacy")
    private var onReading: ((Reading) -> Void)?
    private var systemListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var processListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var inputListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var cameraSystemListener: CMIOObjectPropertyListenerBlock?
    private var cameraListeners: [CMIOObjectID: CMIOObjectPropertyListenerBlock] = [:]
    private var input = AudioObjectID(kAudioObjectUnknown)
    /// Set while VoxOS holds the microphone muted: the device, and its volume before a mute made
    /// by volume (nil for a mute made with the device's own switch).
    private var mutedHere: (device: AudioObjectID, volume: Float32?)?
    private var microphoneWasInUse = false
    private var pending: DispatchWorkItem?

    private static let system = AudioObjectID(kAudioObjectSystemObject)

    func start(onReading: @escaping (Reading) -> Void) {
        queue.async { [self] in
            self.onReading = onReading
            listenToSystem(kAudioHardwarePropertyDefaultInputDevice) { [weak self] in self?.inputChanged() }
            listenToSystem(kAudioHardwarePropertyProcessObjectList) { [weak self] in self?.processesChanged() }
            listenToCameraList()
            inputChanged()
            processesChanged()
            camerasChanged()
        }
    }

    func stop() {
        queue.async { [self] in
            restoreMute()
            for (address, block) in systemListeners {
                var address = address
                AudioObjectRemovePropertyListenerBlock(Self.system, &address, queue, block)
            }
            systemListeners = []
            for (process, block) in processListeners {
                var address = Self.address(kAudioProcessPropertyIsRunningInput)
                AudioObjectRemovePropertyListenerBlock(process, &address, queue, block)
            }
            processListeners = [:]
            removeInputListeners()
            removeCameraListeners()
            if let cameraSystemListener {
                var address = Self.cameraAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
                CMIOObjectRemovePropertyListenerBlock(
                    CMIOObjectID(kCMIOObjectSystemObject), &address, queue, cameraSystemListener)
            }
            cameraSystemListener = nil
            pending?.cancel()
            onReading = nil
        }
    }

    // MARK: Mute

    func setMuted(_ muted: Bool) {
        queue.async { [self] in
            if muted { mute() } else { restoreMute() }
            scheduleReading()
        }
    }

    /// At quit, before the process is gone.
    func restoreMuteNow() {
        queue.sync { restoreMute() }
    }

    private func mute() {
        guard input != kAudioObjectUnknown, mutedHere == nil else { return }
        var muteAddress = Self.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput)
        if Self.isSettable(input, &muteAddress) {
            var value: UInt32 = 1
            if AudioObjectSetPropertyData(input, &muteAddress, 0, nil, 4, &value) == noErr {
                mutedHere = (input, nil)
            }
            return
        }
        guard let volume = Self.volume(of: input) else { return }
        if Self.setVolume(0, of: input) { mutedHere = (input, volume) }
    }

    private func restoreMute() {
        guard let mutedHere else { return }
        self.mutedHere = nil
        if let volume = mutedHere.volume {
            _ = Self.setVolume(volume, of: mutedHere.device)
        } else {
            var muteAddress = Self.address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput)
            var value: UInt32 = 0
            AudioObjectSetPropertyData(mutedHere.device, &muteAddress, 0, nil, 4, &value)
        }
    }

    // MARK: Listening

    private func listenToSystem(_ selector: AudioObjectPropertySelector, _ action: @escaping () -> Void) {
        var address = Self.address(selector)
        let block: AudioObjectPropertyListenerBlock = { _, _ in action() }
        if AudioObjectAddPropertyListenerBlock(Self.system, &address, queue, block) == noErr {
            systemListeners.append((address, block))
        }
    }

    /// The default input's mute and volume, so a mute made elsewhere shows too.
    private func inputChanged() {
        removeInputListeners()
        // A mute made here belongs to the device it was made on.
        restoreMute()
        input = Self.read(Self.system, kAudioHardwarePropertyDefaultInputDevice) ?? AudioObjectID(kAudioObjectUnknown)
        if input != kAudioObjectUnknown {
            // Whether it runs at all, for a call that starts on it.
            var running = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleReading() }
            if AudioObjectAddPropertyListenerBlock(input, &running, queue, block) == noErr {
                inputListeners.append((input, running, block))
            }
            for selector in [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar] {
                var address = Self.address(selector, scope: kAudioObjectPropertyScopeInput)
                guard AudioObjectHasProperty(input, &address) else { continue }
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleReading() }
                if AudioObjectAddPropertyListenerBlock(input, &address, queue, block) == noErr {
                    inputListeners.append((input, address, block))
                }
            }
        }
        scheduleReading()
    }

    private func removeInputListeners() {
        for (device, address, block) in inputListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
        }
        inputListeners = []
    }

    /// A listener on each audio process for whether it runs input; processes come and go.
    private func processesChanged() {
        let processes = Set(Self.readArray(Self.system, kAudioHardwarePropertyProcessObjectList))
        for (process, block) in processListeners where !processes.contains(process) {
            var address = Self.address(kAudioProcessPropertyIsRunningInput)
            AudioObjectRemovePropertyListenerBlock(process, &address, queue, block)
            processListeners[process] = nil
        }
        for process in processes where processListeners[process] == nil {
            var address = Self.address(kAudioProcessPropertyIsRunningInput)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleReading() }
            if AudioObjectAddPropertyListenerBlock(process, &address, queue, block) == noErr {
                processListeners[process] = block
            }
        }
        scheduleReading()
    }

    private func listenToCameraList() {
        var address = Self.cameraAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.camerasChanged() }
        if CMIOObjectAddPropertyListenerBlock(CMIOObjectID(kCMIOObjectSystemObject), &address, queue, block) == 0 {
            cameraSystemListener = block
        }
    }

    private func camerasChanged() {
        removeCameraListeners()
        for camera in Self.cameras() {
            var address = Self.cameraAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleReading() }
            if CMIOObjectAddPropertyListenerBlock(camera, &address, queue, block) == 0 {
                cameraListeners[camera] = block
            }
        }
        scheduleReading()
    }

    private func removeCameraListeners() {
        for (camera, block) in cameraListeners {
            var address = Self.cameraAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
            CMIOObjectRemovePropertyListenerBlock(camera, &address, queue, block)
        }
        cameraListeners = [:]
    }

    // MARK: Reading

    /// Changes come in bursts (a call starts its input and output, joins a camera); one reading
    /// a moment later covers them all.
    private func scheduleReading() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.read() }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func read() {
        var reading = Reading()
        var clients: [(pid: pid_t, bundleID: String?)] = []
        for process in processListeners.keys {
            guard Self.read(process, kAudioProcessPropertyIsRunningInput) == UInt32(1),
                let pid: pid_t = Self.read(process, kAudioProcessPropertyPID)
            else { continue }
            clients.append((pid, Self.readString(process, kAudioProcessPropertyBundleID)))
        }
        let inputRunning = Self.inputDevices().contains {
            Self.read($0, kAudioDevicePropertyDeviceIsRunningSomewhere) == UInt32(1)
        }
        for client in NotchPrivacy.listeners(clients, me: getpid(), inputRunning: inputRunning) {
            reading.microphonePIDs.append(client.pid)
            if let bundleID = client.bundleID { reading.microphoneBundleIDs.append(bundleID) }
        }
        reading.camera = cameraListeners.keys.contains { camera in
            var address = Self.cameraAddress(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
            var running: UInt32 = 0
            var used: UInt32 = 0
            return CMIOObjectGetPropertyData(camera, &address, 0, nil, 4, &used, &running) == 0 && running != 0
        }
        // The call is over: a mute made for it goes with it.
        let inUse = !reading.microphonePIDs.isEmpty
        if microphoneWasInUse, !inUse { restoreMute() }
        microphoneWasInUse = inUse
        reading.muted = Self.isMuted(input)
        onReading?(reading)
    }

    // MARK: Core Audio

    private static func address(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, value) == noErr else { return nil }
        return value.pointee
    }

    private static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
            let text = value?.takeRetainedValue() as String?, !text.isEmpty
        else { return nil }
        return text
    }

    private static func readArray(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    /// Devices with input streams: microphones, headsets, interfaces.
    private static func inputDevices() -> [AudioObjectID] {
        readArray(system, kAudioHardwarePropertyDevices).filter { device in
            var streams = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
            var size: UInt32 = 0
            return AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &size) == noErr && size > 0
        }
    }

    private static func isSettable(_ device: AudioObjectID, _ address: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    private static func isMuted(_ device: AudioObjectID) -> Bool {
        guard device != kAudioObjectUnknown else { return false }
        var muteAddress = address(kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput)
        if AudioObjectHasProperty(device, &muteAddress) {
            var value: UInt32 = 0
            var size = UInt32(4)
            if AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &value) == noErr, value != 0 {
                return true
            }
        }
        return (volume(of: device) ?? 1) <= 0.001
    }

    /// The input volume on the main element, or the first channel's on a device that has only
    /// per-channel volumes.
    private static func volume(of device: AudioObjectID) -> Float32? {
        for element in [kAudioObjectPropertyElementMain, 1] {
            var volumeAddress = address(
                kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput, element: element)
            guard AudioObjectHasProperty(device, &volumeAddress) else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &value) == noErr { return value }
        }
        return nil
    }

    private static func setVolume(_ volume: Float32, of device: AudioObjectID) -> Bool {
        var done = false
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var volumeAddress = address(
                kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput, element: element)
            guard isSettable(device, &volumeAddress) else { continue }
            var value = volume
            if AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
                == noErr
            {
                done = true
            }
        }
        return done
    }

    // MARK: CoreMediaIO

    private static func cameraAddress(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: selector, mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func cameras() -> [CMIOObjectID] {
        var address = cameraAddress(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return [] }
        var cameras = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &cameras) == 0 else { return [] }
        return cameras
    }
}
