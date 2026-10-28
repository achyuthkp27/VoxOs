import AppKit
import AudioToolbox
import Combine
import CoreAudio
import os

/// Volume and brightness in the notch instead of macOS's own pop-up.
///
/// The keys arrive as system-defined events (aux control buttons). A tap of their own, on its
/// own thread, takes them before macOS does — so macOS neither changes anything nor shows its
/// pop-up — and VoxOS makes the change itself: the output's volume through Core Audio, the
/// built-in display's brightness through DisplayServices, in macOS's own steps (a sixteenth, a
/// quarter of that with Option and Shift). The tap needs Accessibility, which VoxOS already has
/// for its shortcuts. A key is only taken while the notch can show the level and the change can
/// be made here; otherwise it goes on to macOS as before (an external display's brightness, a
/// device without volume, the notch hidden or covered).
@MainActor
final class NotchHUD: ObservableObject {
    static let shared = NotchHUD()

    struct Level: Equatable {
        enum Kind: Equatable {
            case volume
            case brightness
        }

        let kind: Kind
        /// 0…1.
        let value: Float
        var muted = false

        var symbol: String {
            switch kind {
            case .volume:
                if muted || value <= 0 { return "speaker.slash.fill" }
                return value < 0.34
                    ? "speaker.wave.1.fill" : value < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
            case .brightness:
                return value < 0.5 ? "sun.min.fill" : "sun.max.fill"
            }
        }
    }

    /// How long the level stays after the last key.
    static let lifetime: TimeInterval = 1.5
    /// macOS's step, and its fine step with Option and Shift.
    nonisolated static let step: Float = 1 / 16
    nonisolated static let fineStep: Float = 1 / 64

    @Published private(set) var level: Level?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.notchHUDEnabled) }

    private let tap = MediaKeyTap()
    private var clearTask: Task<Void, Never>?
    private var tapRetry: Date?
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "NotchHUD")

    private init() {}

    /// Called by Notch Home on every refresh: keys are taken only while it can show them.
    func update(canShow: Bool) {
        let wanted = canShow && Self.isEnabled && !ProcessIdentity.isTestHost
        if wanted, !tap.isInstalled {
            // A tap refused (Accessibility not granted yet) is tried again now and then, not on
            // every refresh.
            if tapRetry.map({ Date().timeIntervalSince($0) > 30 }) ?? true {
                tapRetry = Date()
                tap.install { [weak self] key, fine, shift in
                    Task { @MainActor in self?.press(key, fine: fine, shift: shift) }
                }
                if tap.isInstalled { logger.notice("Media key tap installed") }
            }
        }
        tap.setTaking(
            volume: wanted && SystemVolume.canSet(SystemVolume.defaultOutput()),
            brightness: wanted && DisplayBrightness.canSet())
    }

    private func press(_ key: MediaKeyTap.Key, fine: Bool, shift: Bool) {
        let step = fine ? Self.fineStep : Self.step
        switch key {
        case .volumeUp, .volumeDown, .mute:
            let device = SystemVolume.defaultOutput()
            guard var value = SystemVolume.volume(device) else { return }
            var muted = SystemVolume.isMuted(device)
            switch key {
            case .mute:
                muted.toggle()
            case .volumeUp:
                value = Self.stepped(value, by: step)
                muted = false
            default:
                value = Self.stepped(value, by: -step)
                muted = value <= 0
            }
            if key != .mute { SystemVolume.setVolume(value, device) }
            SystemVolume.setMuted(muted, device)
            show(Level(kind: .volume, value: value, muted: muted))
            if key != .mute, !muted, SystemVolume.playsFeedback != shift { SystemVolume.playFeedback() }
        case .brightnessUp, .brightnessDown:
            guard let value = DisplayBrightness.get() else { return }
            let next = Self.stepped(value, by: key == .brightnessUp ? step : -step)
            DisplayBrightness.set(next)
            show(Level(kind: .brightness, value: next))
        }
        // A device switched or a display gone changes what can be taken.
        tap.setTaking(
            volume: tap.takesVolume && SystemVolume.canSet(SystemVolume.defaultOutput()),
            brightness: tap.takesBrightness && DisplayBrightness.canSet())
    }

    /// The next level on macOS's grid: a press from between two steps lands on the next one.
    nonisolated static func stepped(_ value: Float, by step: Float) -> Float {
        // A hair of slack, so a level read back a rounding error under a step is on it.
        let position = value / abs(step)
        let steps = step > 0 ? (position + 0.001).rounded(.down) + 1 : (position - 0.001).rounded(.up) - 1
        return min(1, max(0, steps * abs(step)))
    }

    private func show(_ level: Level) {
        self.level = level
        clearTask?.cancel()
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.lifetime))
            guard !Task.isCancelled else { return }
            self?.level = nil
        }
    }
}

// MARK: - Keys

/// The tap for the media keys, on its own thread so a busy main thread never holds up the keys
/// (macOS turns off a tap whose callback is slow).
final class MediaKeyTap: @unchecked Sendable {
    enum Key: Int {
        // NX_KEYTYPE_* from IOKit's ev_keymap.h.
        case volumeUp = 0
        case volumeDown = 1
        case brightnessUp = 2
        case brightnessDown = 3
        case mute = 7

        var isVolume: Bool { self == .volumeUp || self == .volumeDown || self == .mute }
    }

    /// NX_SYSDEFINED, and its subtype for aux control buttons.
    static let systemDefined = CGEventType(rawValue: 14)!
    static let auxControlButtons: Int16 = 8

    private let lock = NSLock()
    private var port: CFMachPort?
    private var takingVolume = false
    private var takingBrightness = false
    private var onKey: ((Key, Bool, Bool) -> Void)?

    var isInstalled: Bool { lock.withLock { port != nil } }
    var takesVolume: Bool { lock.withLock { takingVolume } }
    var takesBrightness: Bool { lock.withLock { takingBrightness } }

    func setTaking(volume: Bool, brightness: Bool) {
        lock.withLock {
            takingVolume = volume
            takingBrightness = brightness
        }
    }

    /// `onKey` gets the key, whether Option and Shift were held (the fine step), and whether
    /// Shift was (which flips the feedback sound), once per press and repeat.
    func install(onKey: @escaping (Key, Bool, Bool) -> Void) {
        guard !isInstalled else { return }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<MediaKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
            return tap.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: CGEventMask(1 << Self.systemDefined.rawValue), callback: callback,
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
            self.onKey = onKey
        }
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            while true {
                let result = CFRunLoopRunInMode(.defaultMode, .greatestFiniteMagnitude, false)
                if result == .finished || result == .stopped { break }
            }
        }
        thread.name = "com.achyuthkp.voxos.media-key-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Whether to take the event. Only reads a few fields and a flag, so the keys are never
    /// held up; the change itself is made on the main thread.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = lock.withLock({ port }) { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        }
        guard type == Self.systemDefined, let ns = NSEvent(cgEvent: event),
            ns.subtype.rawValue == Self.auxControlButtons, let decoded = Self.decode(ns.data1)
        else { return false }
        let key = decoded.key
        let down = decoded.down
        let (taking, onKey) = lock.withLock {
            ((key.isVolume ? takingVolume : takingBrightness), self.onKey)
        }
        guard taking else { return false }
        if down {
            let flags = ns.modifierFlags
            onKey?(key, flags.contains(.option) && flags.contains(.shift), flags.contains(.shift))
        }
        // The release too, so macOS never sees half a press.
        return true
    }

    /// From the event's data1: the key in the high 16 bits; in the low ones the state (0xA
    /// down, 0xB up) and the repeat bit.
    static func decode(_ data1: Int) -> (key: Key, down: Bool, repeating: Bool)? {
        guard let key = Key(rawValue: (data1 & 0xFFFF_0000) >> 16) else { return nil }
        let flags = data1 & 0xFFFF
        let state = (flags & 0xFF00) >> 8
        guard state == 0xA || state == 0xB else { return nil }
        return (key, state == 0xA, flags & 0x1 == 1)
    }
}

// MARK: - Volume

/// The default output's volume, as the whole device (all channels together) like the menu bar's
/// slider.
enum SystemVolume {
    private static func address(_ selector: AudioObjectPropertySelector, output: Bool = true)
        -> AudioObjectPropertyAddress
    {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: output ? kAudioDevicePropertyScopeOutput : kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultOutput() -> AudioObjectID {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice, output: false)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    /// Devices without a volume (most HDMI and DisplayPort outputs) are left to macOS.
    static func canSet(_ device: AudioObjectID) -> Bool {
        guard device != kAudioObjectUnknown else { return false }
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &address)
            && AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    static func volume(_ device: AudioObjectID) -> Float? {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    static func setVolume(_ value: Float, _ device: AudioObjectID) {
        var address = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var value = Float32(value)
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    static func isMuted(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyMute)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    static func setMuted(_ muted: Bool, _ device: AudioObjectID) {
        var address = address(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &address) else { return }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    /// Sound settings → "Play feedback when volume is changed" (a global default, which the
    /// standard defaults read through).
    static var playsFeedback: Bool { UserDefaults.standard.bool(forKey: "com.apple.sound.beep.feedback") }

    /// The same click macOS plays, from the system's own copy of it.
    @MainActor static func playFeedback() {
        feedbackSound?.stop()
        feedbackSound?.play()
    }

    @MainActor private static let feedbackSound: NSSound? = NSSound(
        contentsOfFile: "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff",
        byReference: true)
}

// MARK: - Brightness

/// The built-in display's brightness, through DisplayServices (private, loaded at run time; if a
/// future macOS drops it, the keys simply stay with macOS).
enum DisplayBrightness {
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool

    private static let library = dlopen(
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getter = symbol("DisplayServicesGetBrightness", as: GetBrightness.self)
    private static let setter = symbol("DisplayServicesSetBrightness", as: SetBrightness.self)
    private static let checker = symbol("DisplayServicesCanChangeBrightness", as: CanChangeBrightness.self)

    private static func symbol<T>(_ name: String, as: T.Type) -> T? {
        guard let library, let pointer = dlsym(library, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    /// The built-in display, when it is on.
    static var display: CGDirectDisplayID? {
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(displays.count), &displays, &count) == .success else { return nil }
        return displays.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    static func canSet() -> Bool {
        guard let display, getter != nil, setter != nil else { return false }
        return checker?(display) ?? true
    }

    static func get() -> Float? {
        guard let display, let getter else { return nil }
        var value: Float = 0
        return getter(display, &value) == 0 ? value : nil
    }

    static func set(_ value: Float) {
        guard let display, let setter else { return }
        _ = setter(display, value)
    }
}
