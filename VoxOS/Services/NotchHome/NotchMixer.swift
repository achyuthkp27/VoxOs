import AppKit
import Combine
import CoreAudio
import os

/// Per-app volume: each app that can play sound (every app in the Dock, and anything else playing),
/// with its own level under the system's. An app that has not played yet keeps the level it is
/// given, and is turned down the moment it starts.
///
/// macOS has no per-app volume. An app turned down is taken with a Core Audio process tap
/// (macOS 14.2+) that mutes it where it was going, and its sound is played on to the same output
/// at the lower level through a private aggregate device: the method Apple's own sample for taps
/// shows. That is system audio capture, so macOS's purple recording dot shows while any app is
/// turned down, and turning every app back to full removes it. The tap keeps the app muted at
/// its source the whole time (so pausing never lets a burst of full volume through), and the
/// device that plays it on at the lower level runs only while the app is playing; nothing runs
/// for an app at full volume.
@MainActor
final class NotchMixer: ObservableObject {
    static let shared = NotchMixer()

    struct App: Identifiable, Equatable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
        /// Its Core Audio process objects (an app and its helpers).
        let processes: [AudioObjectID]
        var gain: Float
        /// The output device it plays on, by UID; nil for the Mac's default output.
        var output: String? = nil

        var isMuted: Bool { gain <= 0.001 }
    }

    /// A saved set of levels and outputs, applied with one click ("Meeting": Music at 20%, Zoom
    /// on AirPods). Apps it does not name go back to full on the default output.
    struct Preset: Codable, Identifiable, Equatable {
        var id = UUID()
        var name: String
        var levels: [String: Float]
        var outputs: [String: String]
    }

    /// Levels the user set, by app, for this run.
    @Published private(set) var apps: [App] = []
    @Published private(set) var presets: [Preset] = NotchMixer.loadPresets()
    private var gains: [String: Float] = [:]
    /// The level an app had before it was muted, to go back to.
    private var unmuted: [String: Float] = [:]
    /// Apps sent to another output device than the default, by device UID.
    private var outputs: [String: String] = [:]
    private var taps: [String: AppVolumeTap] = [:]
    private var listening = false
    private var listener: AudioObjectPropertyListenerBlock?
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "NotchMixer")

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.notchMixerEnabled) }

    private init() {}

    /// While the Sound page is on screen, or any app is turned down, the list follows the
    /// processes that come and go.
    func setVisible(_ visible: Bool) {
        let wanted = visible || !taps.isEmpty || gains.values.contains { $0 < 0.999 } || !outputs.isEmpty
        guard wanted != listening else {
            if visible { reload() }
            return
        }
        listening = wanted
        var address = Self.processListAddress
        if wanted {
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor in self?.reload() }
            }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
            listener = block
            reload()
        } else if let listener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, listener)
            self.listener = nil
        }
    }

    func setGain(_ gain: Float, for bundleID: String) {
        let gain = min(1, max(0, gain))
        gains[bundleID] = gain
        if let index = apps.firstIndex(where: { $0.bundleID == bundleID }) { apps[index].gain = gain }
        apply(bundleID)
    }

    /// Muted, back to the level it had; at any level, muted.
    func toggleMute(_ bundleID: String) {
        let current = gains[bundleID] ?? 1
        if current <= 0.001 {
            setGain(unmuted.removeValue(forKey: bundleID) ?? 1, for: bundleID)
        } else {
            unmuted[bundleID] = current
            setGain(0, for: bundleID)
        }
    }

    /// Plays the app on the device with `uid`; nil puts it back on the default output.
    func setOutput(_ uid: String?, for bundleID: String) {
        outputs[bundleID] = uid
        if let index = apps.firstIndex(where: { $0.bundleID == bundleID }) { apps[index].output = uid }
        apply(bundleID)
    }

    // MARK: Presets

    /// What is set now (every app turned down or sent elsewhere), kept as a preset.
    func saveCurrentAsPreset() {
        let levels = gains.filter { $0.value < 0.999 }
        guard !levels.isEmpty || !outputs.isEmpty else { return }
        let pairs = NotchAudioOutput.outputDevices().compactMap { device in
            AppVolumeTap.uid(of: device.id).map { ($0, device.name) }
        }
        let devices = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        let name = Self.presetName(
            levels: levels, outputs: outputs, appName: { NotchHomeApp.name(for: $0) ?? $0 },
            deviceName: { devices[$0] ?? $0 })
        presets.append(Preset(name: name, levels: levels, outputs: outputs))
        savePresets()
    }

    func applyPreset(_ preset: Preset) {
        let touched = Set(gains.keys).union(outputs.keys).union(preset.levels.keys).union(preset.outputs.keys)
        gains = preset.levels
        outputs = preset.outputs
        unmuted = [:]
        for index in apps.indices {
            apps[index].gain = gains[apps[index].bundleID] ?? 1
            apps[index].output = outputs[apps[index].bundleID]
        }
        for bundleID in touched { apply(bundleID) }
        setVisible(listening)
    }

    /// What is set now, unnamed, to go back to after a preset applied for a while (a call).
    var current: Preset {
        Preset(name: "", levels: gains.filter { $0.value < 0.999 }, outputs: outputs)
    }

    func deletePreset(_ preset: Preset) {
        presets.removeAll { $0.id == preset.id }
        savePresets()
    }

    /// "Music 20% · Zoom on AirPods": the first few apps it changes, in name order.
    nonisolated static func presetName(
        levels: [String: Float], outputs: [String: String], appName: (String) -> String,
        deviceName: (String) -> String
    ) -> String {
        let apps = Set(levels.keys).union(outputs.keys).map { (id: $0, name: appName($0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let parts = apps.prefix(3).map { app -> String in
            var part = app.name
            if let level = levels[app.id] {
                part += level <= 0.001 ? " " + String(localized: "muted") : " \(Int((level * 100).rounded()))%"
            }
            if let output = outputs[app.id] { part += " → " + deviceName(output) }
            return part
        }
        let more = apps.count > 3 ? " +\(apps.count - 3)" : ""
        return parts.joined(separator: " · ") + more
    }

    private static func loadPresets() -> [Preset] {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKeys.notchVolumePresets) else { return [] }
        return (try? JSONDecoder().decode([Preset].self, from: data)) ?? []
    }

    private func savePresets() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: DefaultsKeys.notchVolumePresets)
        }
    }

    /// Turns every app back to full, as when the feature is switched off.
    func reset() {
        gains = [:]
        unmuted = [:]
        outputs = [:]
        taps.values.forEach { $0.stop() }
        taps = [:]
        for index in apps.indices {
            apps[index].gain = 1
            apps[index].output = nil
        }
        setVisible(false)
    }

    nonisolated private static var processListAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// The apps with audio, grouped by the regular app above each process (a browser's audio
    /// service counts as the browser), playing ones first.
    private func reload() {
        var grouped: [String: (name: String, processes: [AudioObjectID], playing: Bool)] = [:]
        let me = getpid()
        for process in Self.processObjects() {
            guard let pid = Self.pid(of: process), pid != me,
                let app = ClaudeCodeTerminal.app(hosting: pid).flatMap({ NSRunningApplication(processIdentifier: $0) }),
                let bundleID = app.bundleIdentifier
            else { continue }
            var entry = grouped[bundleID] ?? (app.localizedName ?? bundleID, [], false)
            entry.processes.append(process)
            entry.playing = entry.playing || Self.isRunningOutput(process)
            grouped[bundleID] = entry
        }
        // Every app in the Dock can play sound, whether or not it has yet.
        var dockApps = Set<String>()
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != me {
            guard let bundleID = app.bundleIdentifier else { continue }
            dockApps.insert(bundleID)
            if grouped[bundleID] == nil { grouped[bundleID] = (app.localizedName ?? bundleID, [], false) }
        }
        // Helpers and menu bar apps show only while they play, or once turned down.
        let shown = grouped.filter {
            $0.value.playing || dockApps.contains($0.key) || gains[$0.key].map { $0 < 1 } == true
                || outputs[$0.key] != nil
        }
        apps = Self.ordered(
            shown.map {
                (
                    App(
                        bundleID: $0.key, name: $0.value.name, processes: $0.value.processes,
                        gain: gains[$0.key] ?? 1, output: outputs[$0.key]),
                    $0.value.playing
                )
            })
        // An app that started a new helper is taken again with all of its processes.
        for app in apps
        where taps[app.bundleID]?.processes != app.processes
            && ((gains[app.bundleID] ?? 1) < 1 || outputs[app.bundleID] != nil)
        {
            apply(app.bundleID)
        }
    }

    /// Playing apps first, then the rest, each by name.
    nonisolated static func ordered(_ apps: [(App, playing: Bool)]) -> [App] {
        apps.sorted { lhs, rhs in
            if lhs.playing != rhs.playing { return lhs.playing }
            return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
        }
        .map(\.0)
    }

    private func apply(_ bundleID: String) {
        let gain = gains[bundleID] ?? 1
        let output = outputs[bundleID]
        let processes = apps.first { $0.bundleID == bundleID }?.processes ?? []
        if (gain >= 0.999 && output == nil) || processes.isEmpty {
            taps.removeValue(forKey: bundleID)?.stop()
        } else if let tap = taps[bundleID], tap.processes == processes, tap.outputUID == output {
            tap.gain = gain
        } else {
            taps.removeValue(forKey: bundleID)?.stop()
            if let tap = AppVolumeTap(processes: processes, gain: gain, outputUID: output) {
                taps[bundleID] = tap
            } else if output != nil {
                // The device went away: back to the default output rather than silence.
                logger.error("Per-app output not available for \(bundleID, privacy: .public)")
                setOutput(nil, for: bundleID)
                return
            } else {
                logger.error("Per-app volume tap not created for \(bundleID, privacy: .public)")
            }
        }
        setVisible(listening)
    }

    // MARK: Core Audio

    nonisolated static func processObjects() -> [AudioObjectID] {
        var address = processListAddress
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    nonisolated static func pid(of process: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid) == noErr ? pid : nil
    }

    nonisolated static func isRunningOutput(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr && running != 0
    }
}

/// One app's sound, muted where it was going and played on at `gain` through a private
/// aggregate of the tap and an output: the default one, or the device the app was sent to.
final class AppVolumeTap: @unchecked Sendable {
    let processes: [AudioObjectID]
    /// The device it plays on; nil for the default output.
    let outputUID: String?
    /// Read on the audio thread, written on the main one; a 32-bit store is atomic on Apple
    /// silicon and Intel alike.
    private let level = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.achyuthkp.voxos.app-volume", qos: .userInteractive)
    /// Listeners for whether the app plays, which start and stop the device.
    private var playingListeners: [(AudioObjectID, AudioObjectPropertyListenerBlock)] = []
    private var running = false

    var gain: Float {
        get { level.pointee }
        set { level.pointee = min(1, max(0, newValue)) }
    }

    init?(processes: [AudioObjectID], gain: Float, outputUID: String? = nil) {
        self.processes = processes
        self.outputUID = outputUID
        level.initialize(to: min(1, max(0, gain)))
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "VoxOS app volume"
        description.isPrivate = true
        description.muteBehavior = .muted
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(description, &tap) == noErr, tap != kAudioObjectUnknown,
            let output = outputUID ?? Self.uid(of: SystemVolume.defaultOutput())
        else {
            level.deallocate()
            return nil
        }
        tapID = tap
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VoxOS app volume",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: output,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: description.uuid.uuidString]
            ],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device) == noErr else {
            stop()
            return nil
        }
        aggregateID = device
        let level = level
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, input, _, output, _ in
            AppVolumeTap.copy(input, to: output, gain: level.pointee)
        }
        guard status == noErr, let proc else {
            stop()
            return nil
        }
        procID = proc
        queue.sync {
            for process in processes {
                var address = Self.runningOutputAddress
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.followPlaying() }
                if AudioObjectAddPropertyListenerBlock(process, &address, queue, block) == noErr {
                    playingListeners.append((process, block))
                }
            }
            followPlaying()
        }
    }

    private static var runningOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// On the queue: the device runs while any of the app's processes plays.
    private func followPlaying() {
        guard let procID else { return }
        let playing = processes.contains(where: NotchMixer.isRunningOutput)
        guard playing != running else { return }
        running = playing
        if playing { AudioDeviceStart(aggregateID, procID) } else { AudioDeviceStop(aggregateID, procID) }
    }

    /// On the queue, so it never races a start or stop from the app's playing changing.
    func stop() {
        queue.sync {
            for (process, block) in playingListeners {
                var address = Self.runningOutputAddress
                AudioObjectRemovePropertyListenerBlock(process, &address, queue, block)
            }
            playingListeners = []
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            procID = nil
            running = false
            if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    deinit {
        stop()
        level.deallocate()
    }

    /// The tap's channels onto the output's, scaled; an output channel past the tap's takes the
    /// tap's last (mono into stereo). Float32 throughout, as Core Audio's IO procs are. Nothing
    /// here allocates: it runs on the real-time audio thread.
    static func copy(
        _ input: UnsafePointer<AudioBufferList>, to output: UnsafeMutablePointer<AudioBufferList>, gain: Float
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        let inChannels = inputs.reduce(0) { $0 + Int($1.mNumberChannels) }
        var outChannel = 0
        for buffer in outputs {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let channels = max(1, Int(buffer.mNumberChannels))
            let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
            for channel in 0..<channels {
                defer { outChannel += 1 }
                guard inChannels > 0, let source = Self.channel(min(outChannel, inChannels - 1), in: inputs) else {
                    for frame in 0..<frames { data[frame * channels + channel] = 0 }
                    continue
                }
                let count = min(frames, source.frames)
                for frame in 0..<count {
                    data[frame * channels + channel] = source.data[frame * source.stride] * gain
                }
                for frame in count..<frames { data[frame * channels + channel] = 0 }
            }
        }
    }

    private static func channel(
        _ index: Int, in buffers: UnsafeMutableAudioBufferListPointer
    ) -> (data: UnsafeMutablePointer<Float>, stride: Int, frames: Int)? {
        var first = 0
        for buffer in buffers {
            let channels = max(1, Int(buffer.mNumberChannels))
            if index < first + channels, let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                return (
                    data + (index - first), channels, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels
                )
            }
            first += channels
        }
        return nil
    }

    /// A device's UID, which an aggregate names its parts by.
    static func uid(of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }
}
