@preconcurrency import AVFoundation
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreAudio
import os

/// A switch's sound on every key typed, from the keyboard itself: presses and releases, each key
/// placed left or right by where it sits on the keyboard, the pitch varied a little press to press,
/// and the space bar, Return and Delete sounding like the bigger keys they are.
///
/// Only keys typed on a keyboard sound: a key VoxOS or another app posts (a paste, a text
/// expander) and a key held down to repeat do not. Nothing sounds while an app chosen in Settings
/// is in front, or, unless switched off, while any app (VoxOS's own dictation and meeting notes
/// included) is listening to the microphone, so a call or a recording never picks the clicks up.
/// The keys are read by a listen-only tap on its own thread, which needs Accessibility. Off until
/// switched on in Settings.
@MainActor
final class KeySounds: ObservableObject {
    static let shared = KeySounds()

    /// What the player needs to know, read from the settings.
    struct Settings: Equatable, Sendable {
        var enabled = false
        var profile = KeySoundSynth.Profile.creamy
        var volume: Float = 0.6
        var keyUp = true
        var stereo = true
        var varyPitch = true
        var quietWhileMicrophone = true
        var quietApps: Set<String> = []

        static func read(from defaults: UserDefaults = .standard) -> Settings {
            Settings(
                enabled: defaults.bool(forKey: DefaultsKeys.keySoundsEnabled),
                profile: defaults.string(forKey: DefaultsKeys.keySoundsProfile).flatMap(KeySoundSynth.Profile.init)
                    ?? .creamy,
                volume: Float(defaults.double(forKey: DefaultsKeys.keySoundsVolume)),
                keyUp: defaults.bool(forKey: DefaultsKeys.keySoundsKeyUp),
                stereo: defaults.bool(forKey: DefaultsKeys.keySoundsStereo),
                varyPitch: defaults.bool(forKey: DefaultsKeys.keySoundsVaryPitch),
                quietWhileMicrophone: defaults.bool(forKey: DefaultsKeys.keySoundsQuietWhileMicrophone),
                quietApps: Set(defaults.stringArray(forKey: DefaultsKeys.keySoundsQuietApps) ?? []))
        }
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.keySoundsEnabled) }

    @Published private(set) var isTapInstalled = false
    @Published private(set) var quietApps: [String]

    private let player = KeySoundPlayer()
    private let tap = KeySoundTap()
    private var settings = Settings()
    private var observers: [NSObjectProtocol] = []
    private var accessTask: Task<Void, Never>?
    private var started = false
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "KeySounds")

    private init() {
        quietApps = UserDefaults.standard.stringArray(forKey: DefaultsKeys.keySoundsQuietApps) ?? []
    }

    /// Called at launch, and again by itself whenever a setting changes (from Settings, the menu
    /// bar or a restored backup).
    func refresh() {
        startWatching()
        let next = Settings.read()
        let apps = UserDefaults.standard.stringArray(forKey: DefaultsKeys.keySoundsQuietApps) ?? []
        if apps != quietApps { quietApps = apps }
        guard next != settings || (next.enabled && !tap.isInstalled) else { return }
        settings = next
        let wanted = next.enabled && !ProcessIdentity.isTestHost
        player.apply(next)
        if wanted, !tap.isInstalled {
            tap.install { [player] event in player.handle(event) }
            if tap.isInstalled { logger.notice("Key sounds tap installed") }
        }
        tap.setEnabled(wanted)
        if !wanted { player.idleNow() }
        isTapInstalled = tap.isInstalled
        watchForAccess(wanted && !tap.isInstalled)
    }

    /// A few keys typed on `profile`, so a switch can be heard before it is chosen, whether or not
    /// Key Sounds is on.
    func preview(_ profile: KeySoundSynth.Profile) {
        guard !ProcessIdentity.isTestHost else { return }
        player.preview(profile, volume: max(settings.volume, 0.3))
    }

    // MARK: Quiet apps

    func quiet(appAt url: URL) {
        guard let id = Bundle(url: url)?.bundleIdentifier, !quietApps.contains(id) else { return }
        UserDefaults.standard.set(quietApps + [id], forKey: DefaultsKeys.keySoundsQuietApps)
        refresh()
    }

    func stopQuieting(_ bundleID: String) {
        UserDefaults.standard.set(quietApps.filter { $0 != bundleID }, forKey: DefaultsKeys.keySoundsQuietApps)
        refresh()
    }

    // MARK: Watching

    private func startWatching() {
        guard !started else { return }
        started = true
        player.setFrontmost(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [player] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                player.setFrontmost(app?.bundleIdentifier)
            })
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
    }

    /// Accessibility granted after the switch was turned on: the tap is installed as soon as it
    /// is, without waiting for Settings to be opened again.
    private func watchForAccess(_ waiting: Bool) {
        guard waiting else {
            accessTask?.cancel()
            accessTask = nil
            return
        }
        guard accessTask == nil else { return }
        accessTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, AXIsProcessTrusted() else { continue }
                self?.accessTask = nil
                self?.refresh()
                return
            }
        }
    }
}

// MARK: - Keys

/// A key event as the tap saw it.
struct KeySoundEvent: Sendable {
    enum Kind: Sendable {
        case down
        case up
        case modifier
    }

    let kind: Kind
    let keyCode: Int64
    /// Held down long enough that the keyboard is repeating it.
    let isRepeat: Bool
    /// Typed on a keyboard, rather than posted by an app.
    let isFromKeyboard: Bool
    /// The device-dependent modifier bits after a modifier changed.
    let flags: UInt64
}

/// Which keys sound like what, and where they sit.
enum KeySoundKeys {
    static func keyClass(_ keyCode: Int64) -> KeySoundSynth.KeyClass {
        switch Int(keyCode) {
        case kVK_Space: return .space
        case kVK_Return, kVK_ANSI_KeypadEnter: return .returnKey
        case kVK_Delete, kVK_ForwardDelete: return .backspace
        case kVK_Shift, kVK_RightShift, kVK_Control, kVK_RightControl, kVK_Option, kVK_RightOption, kVK_Command,
            kVK_RightCommand, kVK_CapsLock, kVK_Function:
            return .modifier
        default: return .standard
        }
    }

    /// The device-dependent flag each modifier key sets while held (IOKit's IOLLEvent.h); caps
    /// lock and fn are left out, as their bit says whether they are on, not whether they are down.
    static let modifierBits: [Int: UInt64] = [
        kVK_Control: 0x01, kVK_Shift: 0x02, kVK_RightShift: 0x04, kVK_Command: 0x08, kVK_RightCommand: 0x10,
        kVK_Option: 0x20, kVK_RightOption: 0x40, kVK_RightControl: 0x2000,
    ]

    /// Where a key sits across an ANSI keyboard, from 0 (left edge) to 1 (right edge).
    static func position(_ keyCode: Int64) -> Double {
        (columns[Int(keyCode)] ?? 7.5) / 15
    }

    /// Stereo pan for a key: the left-hand keys to the left, the right-hand keys to the right, by
    /// at most `spread`.
    static func pan(_ keyCode: Int64, spread: Double = 0.7) -> Float {
        Float((position(keyCode) - 0.5) * 2 * spread)
    }

    /// The middle of each key, in key widths from the left edge of the keyboard.
    private static let columns: [Int: Double] = {
        var map: [Int: Double] = [:]
        func row(_ keys: [Int], from start: Double) {
            for (index, key) in keys.enumerated() { map[key] = start + Double(index) }
        }
        row(
            [
                kVK_ANSI_Grave, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7,
                kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0, kVK_ANSI_Minus, kVK_ANSI_Equal,
            ], from: 0.5)
        row(
            [
                kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_E, kVK_ANSI_R, kVK_ANSI_T, kVK_ANSI_Y, kVK_ANSI_U, kVK_ANSI_I,
                kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_LeftBracket, kVK_ANSI_RightBracket,
            ], from: 2)
        row(
            [
                kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_D, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_J, kVK_ANSI_K,
                kVK_ANSI_L, kVK_ANSI_Semicolon, kVK_ANSI_Quote,
            ], from: 2.25)
        row(
            [
                kVK_ANSI_Z, kVK_ANSI_X, kVK_ANSI_C, kVK_ANSI_V, kVK_ANSI_B, kVK_ANSI_N, kVK_ANSI_M, kVK_ANSI_Comma,
                kVK_ANSI_Period, kVK_ANSI_Slash,
            ], from: 2.75)
        row(
            [
                kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12,
            ], from: 1.75)
        let singles: [Int: Double] = [
            kVK_Escape: 0.5, kVK_Delete: 14, kVK_Tab: 0.75, kVK_ANSI_Backslash: 14.25, kVK_CapsLock: 0.9,
            kVK_Return: 14, kVK_Shift: 1.1, kVK_RightShift: 13.9, kVK_Function: 0.5, kVK_Control: 1.5,
            kVK_Option: 2.5, kVK_Command: 3.6, kVK_Space: 7.5, kVK_RightCommand: 11.4, kVK_RightOption: 12.5,
            kVK_LeftArrow: 13, kVK_DownArrow: 14, kVK_UpArrow: 14, kVK_RightArrow: 15, kVK_ForwardDelete: 14.5,
            kVK_RightControl: 13.5, kVK_ANSI_KeypadEnter: 15,
        ]
        map.merge(singles) { _, new in new }
        return map
    }()
}

/// The listen-only tap that hears every key, on a thread of its own.
final class KeySoundTap: @unchecked Sendable {
    private let lock = NSLock()
    private var port: CFMachPort?
    private var enabled = false
    private var onEvent: (@Sendable (KeySoundEvent) -> Void)?

    var isInstalled: Bool { lock.withLock { port != nil } }

    func setEnabled(_ on: Bool) {
        lock.withLock {
            enabled = on
            if let port { CGEvent.tapEnable(tap: port, enable: on) }
        }
    }

    func install(onEvent: @escaping @Sendable (KeySoundEvent) -> Void) {
        guard !isInstalled else { return }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            if let userInfo {
                Unmanaged<KeySoundTap>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
            }
            return Unmanaged.passUnretained(event)
        }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                eventsOfInterest: mask, callback: callback,
                // The tap lives as long as the app; so does this.
                userInfo: Unmanaged.passRetained(self).toOpaque())
        else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return
        }
        lock.withLock {
            self.port = port
            self.onEvent = onEvent
        }
        let thread = Thread { [weak self] in
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            if let self { self.lock.withLock { CGEvent.tapEnable(tap: port, enable: self.enabled) } }
            while true {
                let result = CFRunLoopRunInMode(.defaultMode, .greatestFiniteMagnitude, false)
                if result == .finished || result == .stopped { break }
            }
        }
        thread.name = "com.achyuthkp.voxos.key-sounds-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.withLock {
                if let port, enabled { CGEvent.tapEnable(tap: port, enable: true) }
            }
            return
        }
        let kind: KeySoundEvent.Kind
        switch type {
        case .keyDown: kind = .down
        case .keyUp: kind = .up
        case .flagsChanged: kind = .modifier
        default: return
        }
        // Keys typed on a keyboard come from the HID system's own event source; keys an app posts
        // (VoxOS pasting, a text expander) come from a private or combined one.
        let source = event.getIntegerValueField(.eventSourceStateID)
        let keyEvent = KeySoundEvent(
            kind: kind, keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
            isFromKeyboard: source == Int64(CGEventSourceStateID.hidSystemState.rawValue),
            flags: event.flags.rawValue)
        lock.withLock { onEvent }?(keyEvent)
    }
}

// MARK: - Playing

/// Plays the sounds: a small pool of voices on one audio engine, all touched from one queue. The
/// engine stops after a while without keys, so an idle Mac is not kept running its sound output.
final class KeySoundPlayer: @unchecked Sendable {
    private static let voiceCount = 12
    private static let idleStop: TimeInterval = 20
    /// How long a microphone reading is trusted.
    private static let microphoneRecheck: TimeInterval = 1

    private let queue = DispatchQueue(label: "com.achyuthkp.voxos.keySounds", qos: .userInteractive)
    private let engine = AVAudioEngine()
    private var voices: [AVAudioPlayerNode] = []
    private var nextVoice = 0
    private var built = false
    private var settings = KeySounds.Settings()
    private var bank: [KeySoundSynth.SoundKey: [AVAudioPCMBuffer]] = [:]
    private var bankProfile: KeySoundSynth.Profile?
    private var lastVariant: [KeySoundSynth.SoundKey: Int] = [:]
    private var rng = SplitMix(seed: UInt64(Date().timeIntervalSince1970))
    private var frontmost: String?
    private var heldModifiers = Set<Int64>()
    private var idleWork: DispatchWorkItem?
    private var microphoneInUse = false
    private var microphoneCheckedAt = Date.distantPast
    private var configurationObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "KeySounds")

    func apply(_ next: KeySounds.Settings) {
        queue.async { [self] in
            settings = next
            engine.mainMixerNode.outputVolume = next.volume
            if next.enabled, bankProfile != next.profile {
                bank = KeySoundSynth.makeBank(for: next.profile)
                bankProfile = next.profile
                lastVariant = [:]
            }
        }
    }

    func setFrontmost(_ bundleID: String?) {
        queue.async { [self] in frontmost = bundleID }
    }

    /// Stops the engine now rather than after the idle wait: Key Sounds was switched off.
    func idleNow() {
        queue.async { [self] in
            idleWork?.cancel()
            if engine.isRunning { engine.stop() }
            heldModifiers.removeAll()
        }
    }

    func handle(_ event: KeySoundEvent) {
        queue.async { [self] in play(event) }
    }

    func preview(_ profile: KeySoundSynth.Profile, volume: Float) {
        queue.async { [self] in
            let previewBank = profile == bankProfile ? bank : KeySoundSynth.makeBank(for: profile)
            guard prepare() else { return }
            engine.mainMixerNode.outputVolume = volume
            // "hello world" and Return, at an easy typing pace.
            let keys: [Int] = [
                kVK_ANSI_H, kVK_ANSI_E, kVK_ANSI_L, kVK_ANSI_L, kVK_ANSI_O, kVK_Space, kVK_ANSI_W, kVK_ANSI_O,
                kVK_ANSI_R, kVK_ANSI_L, kVK_ANSI_D, kVK_Return,
            ]
            for (index, key) in keys.enumerated() {
                let at = Double(index) * 0.13 + rng.nextUnit() * 0.03
                let code = Int64(key)
                let keyClass = KeySoundKeys.keyClass(code)
                queue.asyncAfter(deadline: .now() + at) { [self] in
                    schedule(previewBank, KeySoundSynth.SoundKey(keyClass: keyClass, stroke: .down), code, true)
                }
                queue.asyncAfter(deadline: .now() + at + 0.07) { [self] in
                    schedule(previewBank, KeySoundSynth.SoundKey(keyClass: keyClass, stroke: .up), code, true)
                }
            }
            queue.asyncAfter(deadline: .now() + Double(keys.count) * 0.13 + 0.4) { [self] in
                engine.mainMixerNode.outputVolume = settings.volume
                scheduleIdleStop()
            }
        }
    }

    // MARK: On the queue

    private func play(_ event: KeySoundEvent) {
        guard settings.enabled, event.isFromKeyboard, !event.isRepeat else { return }
        if let frontmost, settings.quietApps.contains(frontmost) { return }
        let stroke: KeySoundSynth.Stroke
        switch event.kind {
        case .down: stroke = .down
        case .up:
            guard settings.keyUp else { return }
            stroke = .up
        case .modifier:
            guard let modifierStroke = modifierStroke(event) else { return }
            if modifierStroke == .up, !settings.keyUp { return }
            stroke = modifierStroke
        }
        if settings.quietWhileMicrophone, isMicrophoneInUse() { return }
        let key = KeySoundSynth.SoundKey(keyClass: KeySoundKeys.keyClass(event.keyCode), stroke: stroke)
        guard prepare() else { return }
        schedule(bank, key, event.keyCode, settings.varyPitch)
        scheduleIdleStop()
    }

    /// Whether a modifier went down or came up. Caps lock and fn say only that they changed, so
    /// each change is a press.
    private func modifierStroke(_ event: KeySoundEvent) -> KeySoundSynth.Stroke? {
        guard KeySoundKeys.keyClass(event.keyCode) == .modifier else { return nil }
        guard let bit = KeySoundKeys.modifierBits[Int(event.keyCode)] else { return .down }
        if event.flags & bit != 0 {
            heldModifiers.insert(event.keyCode)
            return .down
        }
        return heldModifiers.remove(event.keyCode) != nil ? .up : nil
    }

    private func schedule(
        _ bank: [KeySoundSynth.SoundKey: [AVAudioPCMBuffer]], _ key: KeySoundSynth.SoundKey, _ keyCode: Int64,
        _ vary: Bool
    ) {
        guard let variants = bank[key], !variants.isEmpty else { return }
        var index = 0
        if vary, variants.count > 1 {
            // Any variant but the one this key played last.
            index = Int(rng.nextUnit() * Double(variants.count - 1))
            if index >= (lastVariant[key] ?? -1) { index += 1 }
            index = min(index, variants.count - 1)
        }
        lastVariant[key] = index
        let voice = voices[nextVoice]
        nextVoice = (nextVoice + 1) % voices.count
        voice.pan = settings.stereo ? KeySoundKeys.pan(keyCode) : 0
        voice.scheduleBuffer(variants[index], at: nil, options: .interrupts, completionHandler: nil)
        if !voice.isPlaying { voice.play() }
    }

    /// Builds the voices once and starts the engine if it is stopped.
    private func prepare() -> Bool {
        if !built {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: KeySoundSynth.sampleRate, channels: 1)
            else { return false }
            for _ in 0..<Self.voiceCount {
                let voice = AVAudioPlayerNode()
                engine.attach(voice)
                engine.connect(voice, to: engine.mainMixerNode, format: format)
                voices.append(voice)
            }
            engine.mainMixerNode.outputVolume = settings.volume
            engine.prepare()
            // A new output device (headphones plugged in) stops the engine; the next key starts it.
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                self?.queue.async { self?.voices.forEach { $0.stop() } }
            }
            built = true
        }
        guard !engine.isRunning else { return true }
        do {
            try engine.start()
            return true
        } catch {
            logger.error("Key sounds engine did not start: \(error, privacy: .public)")
            return false
        }
    }

    private func scheduleIdleStop() {
        idleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.engine.isRunning else { return }
            self.voices.forEach { $0.stop() }
            self.engine.stop()
        }
        idleWork = work
        queue.asyncAfter(deadline: .now() + Self.idleStop, execute: work)
    }

    private func isMicrophoneInUse() -> Bool {
        let now = Date()
        if now.timeIntervalSince(microphoneCheckedAt) > Self.microphoneRecheck {
            microphoneInUse = MicrophoneUse.isAnyAppListening()
            microphoneCheckedAt = now
        }
        return microphoneInUse
    }
}

/// Whether any process (VoxOS included) is recording from a microphone right now. Siri's voice
/// trigger reports running input all day without a microphone running (see `NotchPrivacy`), so it
/// is left out, and an input device must be running as well.
enum MicrophoneUse {
    static func isAnyAppListening() -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        let processes: [AudioObjectID] = list(system, kAudioHardwarePropertyProcessObjectList)
        let listening = processes.contains { process in
            guard read(process, kAudioProcessPropertyIsRunningInput) == UInt32(1) else { return false }
            let bundle = bundleID(process)
            return bundle.map { !NotchPrivacy.backgroundListeners.contains($0) } ?? true
        }
        guard listening else { return false }
        let devices: [AudioObjectID] = list(system, kAudioHardwarePropertyDevices)
        return devices.contains { device in
            hasInput(device) && read(device, kAudioDevicePropertyDeviceIsRunningSomewhere) == UInt32(1)
        }
    }

    private static func address(
        _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func list(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func read(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func bundleID(_ process: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func hasInput(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }
}
