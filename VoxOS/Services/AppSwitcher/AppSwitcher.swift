import AppKit
import Carbon.HIToolbox
import Combine
import os

/// Right Command (or Right Option, as chosen in Settings) and a letter brings an app forward: the app whose name starts with the letter,
/// or the one given that letter. The same letter again hides the app, or — when several apps
/// share the letter — moves on to the next. Right Command, Right Option and a letter gives the
/// frontmost app that letter, and a given letter launches its app when it is not running.
///
/// Left Command is never touched, so ⌘C and ⌘V work as always; only Right Command with a bare
/// letter (no Shift or Control) is taken. The keys are read by a tap on its own thread, which
/// needs Accessibility (VoxOS already has it for its shortcuts). Off until switched on in Settings.
@MainActor
final class AppSwitcher: ObservableObject {
    static let shared = AppSwitcher()

    /// A regular app, by bundle identifier and the name it shows.
    struct App: Equatable {
        let id: String
        let name: String
    }

    /// The key held with a letter. The other right-hand key, held as well, gives the letter.
    enum Trigger: String, CaseIterable, Identifiable {
        case rightCommand
        case rightOption

        var id: String { rawValue }

        var title: String {
            switch self {
            case .rightCommand: return String(localized: "Right ⌘ Command")
            case .rightOption: return String(localized: "Right ⌥ Option")
            }
        }

        /// How the notch writes it: "Right ⌘".
        var short: String { self == .rightCommand ? String(localized: "Right ⌘") : String(localized: "Right ⌥") }
        /// The key held with it to give a letter.
        var assignKey: String { self == .rightCommand ? "⌥" : "⌘" }

        var keys: LetterKeyTap.Keys {
            switch self {
            case .rightCommand:
                return LetterKeyTap.Keys(
                    trigger: LetterKeyTap.rightCommand, blocked: LetterKeyTap.leftCommand,
                    assign: LetterKeyTap.rightOption)
            case .rightOption:
                return LetterKeyTap.Keys(
                    trigger: LetterKeyTap.rightOption, blocked: LetterKeyTap.leftOption | LetterKeyTap.leftCommand,
                    assign: LetterKeyTap.rightCommand)
            }
        }
    }

    enum Action: Equatable {
        case activate(String)
        case hide(String)
        case launch(String)
        case nothing
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.appSwitcherEnabled) }
    static var trigger: Trigger {
        UserDefaults.standard.string(forKey: DefaultsKeys.appSwitcherTrigger).flatMap(Trigger.init(rawValue:))
            ?? .rightCommand
    }
    /// The letters an app can be given, in order.
    nonisolated static let alphabet = (UnicodeScalar("a").value...UnicodeScalar("z").value)
        .compactMap(UnicodeScalar.init).map { String(Character($0)) }
    /// How long a notice stays in the notch.
    static let noticeLifetime: TimeInterval = 1.8

    /// Letters given to apps, lowercased, to bundle identifiers.
    @Published private(set) var assignments: [String: String]
    /// What the notch says after a letter is given, or when a letter has no app.
    @Published private(set) var notice: NotchHome.Notice?
    @Published private(set) var isTapInstalled = false

    private let tap = LetterKeyTap()
    /// Bundle identifiers, the most recently active first.
    private var recent: [String] = []
    private var observers: [NSObjectProtocol] = []
    private var noticeTask: Task<Void, Never>?
    private var started = false
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "AppSwitcher")

    private init() {
        assignments =
            UserDefaults.standard.dictionary(forKey: DefaultsKeys.appSwitcherLetters) as? [String: String] ?? [:]
    }

    /// Called at launch and whenever the switch in Settings changes.
    func refresh() {
        let wanted = Self.isEnabled && !ProcessIdentity.isTestHost
        if wanted { startWatching() }
        if wanted, !tap.isInstalled {
            tap.install { [weak self] letter, assign in
                Task { @MainActor in self?.press(letter, assign: assign) }
            }
            if tap.isInstalled { logger.notice("App switcher tap installed") }
        }
        tap.setLetters(Self.letterKeys())
        tap.setKeys(Self.trigger.keys)
        tap.setEnabled(wanted)
        isTapInstalled = tap.isInstalled
    }

    func removeAssignment(_ letter: String) {
        assignments[letter] = nil
        save()
    }

    /// Gives an app a letter from Settings; the app loses any letter it had, and an app that held
    /// this letter loses it.
    func assign(_ letter: String, to bundleID: String) {
        assignments = Self.assigning(letter, to: bundleID, in: assignments)
        save()
    }

    /// Adds an app chosen in Settings: its name's first letter when that is free, otherwise the
    /// first free one. Nothing when it already has a letter or every letter is taken.
    func add(appAt url: URL) {
        guard let id = Bundle(url: url)?.bundleIdentifier, !assignments.values.contains(id) else { return }
        let name = FileManager.default.displayName(atPath: url.path)
        guard let letter = Self.freeLetter(preferring: Self.letter(of: name), in: assignments) else { return }
        assign(letter, to: id)
    }

    nonisolated static func freeLetter(preferring wanted: String?, in assignments: [String: String]) -> String? {
        if let wanted, alphabet.contains(wanted), assignments[wanted] == nil { return wanted }
        return alphabet.first { assignments[$0] == nil }
    }

    // MARK: Keys

    private func press(_ letter: String, assign: Bool) {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if assign {
            guard let app = frontmost, app.activationPolicy == .regular, let id = app.bundleIdentifier else { return }
            assignments = Self.assigning(letter, to: id, in: assignments)
            save()
            show(
                NotchHome.Notice(
                    symbol: "command", title: app.localizedName ?? id,
                    detail: "\(Self.trigger.short) \(letter.uppercased())"))
            return
        }
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
        let apps = running.map { App(id: $0.bundleIdentifier!, name: $0.localizedName ?? "") }
        let action = Self.action(
            for: letter, frontmost: frontmost?.bundleIdentifier, running: apps, assignments: assignments,
            recent: recent)
        switch action {
        case .activate(let id), .launch(let id):
            // Opened as the Dock opens an app: from a background app, macOS can refuse a plain
            // activate, and this also unhides the app and gives it a window when it has none.
            let url =
                running.first(where: { $0.bundleIdentifier == id })?.bundleURL
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            guard let url else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        case .hide(let id):
            running.first(where: { $0.bundleIdentifier == id })?.hide()
        case .nothing:
            show(
                NotchHome.Notice(
                    symbol: "command", title: String(localized: "Nothing on \(letter.uppercased())"),
                    detail: String(
                        localized:
                            "\(Self.trigger.short) \(Self.trigger.assignKey) \(letter.uppercased()) to set one")))
        }
    }

    // MARK: Choosing

    /// The first letter of an app's name, lowercased and without accents; nil when it is not a letter.
    nonisolated static func letter(of name: String) -> String? {
        guard let first = name.trimmingCharacters(in: .whitespaces).first, first.isLetter else { return nil }
        return String(first).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    /// The apps a letter reaches, in the order the letter walks them: the app given the letter,
    /// then the running apps whose name starts with it, by name — leaving out apps given another
    /// letter, which answer to that one instead.
    nonisolated static func candidates(for letter: String, running: [App], assignments: [String: String]) -> [String] {
        var ids: [String] = []
        if let id = assignments[letter] { ids.append(id) }
        let elsewhere = Set(assignments.filter { $0.key != letter }.map(\.value))
        let named =
            running
            .filter { Self.letter(of: $0.name) == letter && !elsewhere.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for app in named where !ids.contains(app.id) { ids.append(app.id) }
        return ids
    }

    /// What a letter does: an app already in front is hidden, or gives way to the next app with
    /// the letter; otherwise the given app, or the one used most recently, comes forward —
    /// launched when it is not running.
    nonisolated static func action(
        for letter: String, frontmost: String?, running: [App], assignments: [String: String], recent: [String]
    ) -> Action {
        let ids = candidates(for: letter, running: running, assignments: assignments)
        guard let first = ids.first else { return .nothing }
        let runningIDs = Set(running.map(\.id))
        func bring(_ id: String) -> Action { runningIDs.contains(id) ? .activate(id) : .launch(id) }
        if let frontmost, let index = ids.firstIndex(of: frontmost) {
            return ids.count == 1 ? .hide(frontmost) : bring(ids[(index + 1) % ids.count])
        }
        if assignments[letter] != nil { return bring(first) }
        let rank = { (id: String) in recent.firstIndex(of: id) ?? Int.max }
        return bring(ids.min { rank($0) < rank($1) } ?? first)
    }

    /// One letter per app: giving an app a letter takes it off any letter it had.
    nonisolated static func assigning(_ letter: String, to id: String, in assignments: [String: String])
        -> [String: String]
    {
        var next = assignments.filter { $0.value != id }
        next[letter] = id
        return next
    }

    // MARK: Plumbing

    private func save() {
        UserDefaults.standard.set(assignments, forKey: DefaultsKeys.appSwitcherLetters)
    }

    private func show(_ notice: NotchHome.Notice) {
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.noticeLifetime))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// Follows which app was used last, and the keyboard layout the letters are read in.
    private func startWatching() {
        guard !started else { return }
        started = true
        if let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier { recent = [id] }
        observers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
            ) { [weak self] note in
                let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .bundleIdentifier
                Task { @MainActor in
                    guard let self, let id else { return }
                    self.recent.removeAll { $0 == id }
                    self.recent.insert(id, at: 0)
                    if self.recent.count > 50 { self.recent.removeLast() }
                }
            })
        observers.append(
            DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.tap.setLetters(Self.letterKeys()) }
            })
    }

    /// The letter each key types in the current layout with no modifier, by key code. Read here,
    /// on the main thread, since the layout calls are not safe on the tap's thread.
    static func letterKeys() -> [Int64: String] {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return [:] }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var letters: [Int64: String] = [:]
        data.withUnsafeBytes { raw in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
                guard status == noErr, length == 1 else { continue }
                let text = String(utf16CodeUnits: characters, count: length)
                if let letter = letter(of: text) { letters[Int64(code)] = letter }
            }
        }
        return letters
    }
}

/// The tap for Right Command and a letter, on its own thread so a busy main thread never holds up
/// typing (macOS turns off a tap whose callback is slow). Only looks up a key code and a few
/// flags; the switching itself happens on the main thread.
final class LetterKeyTap: @unchecked Sendable {
    // Device-dependent modifier bits from IOKit's IOLLEvent.h.
    static let leftCommand: UInt64 = 0x08
    static let rightCommand: UInt64 = 0x10
    static let leftOption: UInt64 = 0x20
    static let rightOption: UInt64 = 0x40

    /// The key that must be held, the keys that must not be (their left-hand twins, so ordinary
    /// shortcuts pass), and the key that, held as well, gives the letter.
    struct Keys: Equatable {
        let trigger: UInt64
        let blocked: UInt64
        let assign: UInt64
    }

    private let lock = NSLock()
    private var port: CFMachPort?
    private var enabled = false
    private var keys = AppSwitcher.Trigger.rightCommand.keys
    private var letters: [Int64: String] = [:]
    /// Key codes whose press was taken, so their release is taken too.
    private var taken = Set<Int64>()
    private var onLetter: ((String, Bool) -> Void)?

    var isInstalled: Bool { lock.withLock { port != nil } }

    func setEnabled(_ on: Bool) { lock.withLock { enabled = on } }
    func setLetters(_ map: [Int64: String]) { lock.withLock { letters = map } }
    func setKeys(_ keys: Keys) { lock.withLock { self.keys = keys } }

    /// `onLetter` gets the letter and whether the assign key was held (giving the letter), once
    /// per press; repeats are taken but not passed on.
    func install(onLetter: @escaping (String, Bool) -> Void) {
        guard !isInstalled else { return }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<LetterKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
            return tap.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
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
            self.onLetter = onLetter
        }
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            while true {
                let result = CFRunLoopRunInMode(.defaultMode, .greatestFiniteMagnitude, false)
                if result == .finished || result == .stopped { break }
            }
        }
        thread.name = "com.achyuthkp.voxos.app-switcher-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Whether to take the event.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = lock.withLock({ port }) { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp {
            return lock.withLock { taken.remove(code) != nil }
        }
        guard type == .keyDown else { return false }
        let flags = event.flags
        let (letters, keys) = lock.withLock { (enabled ? self.letters : [:], self.keys) }
        guard
            let letter = Self.letter(
                code: code, flags: flags.rawValue,
                shiftOrControl: flags.contains(.maskShift) || flags.contains(.maskControl), letters: letters,
                keys: keys)
        else { return false }
        let repeating = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let onLetter = lock.withLock {
            taken.insert(code)
            return self.onLetter
        }
        if !repeating { onLetter?(letter, flags.rawValue & keys.assign != 0) }
        return true
    }

    /// The letter to act on: a letter key with the trigger held, its left-hand twin not, and no
    /// Shift or Control; nil for anything else, which goes on to the app as usual.
    static func letter(
        code: Int64, flags: UInt64, shiftOrControl: Bool, letters: [Int64: String],
        keys: Keys = AppSwitcher.Trigger.rightCommand.keys
    ) -> String? {
        guard flags & keys.trigger != 0, flags & keys.blocked == 0, !shiftOrControl else { return nil }
        return letters[code]
    }
}
