import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import os

/// Right Command (or Right Option, as chosen in Settings) and a letter brings an app forward: the app whose name starts with the letter,
/// or the one given that letter. The same letter again hides the app, or — when several apps
/// share the letter — moves on to the next. Right Command, Right Option and a letter gives the
/// frontmost app that letter, and a given letter launches its app when it is not running.
/// Holding the key alone for a moment shows every letter and the app it reaches.
///
/// Left Command is never touched, so ⌘C and ⌘V work as always; only Right Command with a bare
/// letter (no Shift or Control) is taken, and nothing is taken while an app chosen in Settings is
/// in front. Letters are read in the ASCII-capable layout, so they keep working while a Cyrillic,
/// Greek or other layout is selected. The keys are read by a tap on its own thread, which needs
/// Accessibility (VoxOS already has it for its shortcuts). Off until switched on in Settings.
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
        /// The only app on the letter is already in front, and Settings says to leave it.
        case stay
        case nothing
    }

    /// A letter and the app it reaches now, for the letters shown while the key is held.
    struct Reach: Equatable {
        let letter: String
        let id: String
        /// Given this letter, rather than reached by its name.
        let assigned: Bool
    }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.appSwitcherEnabled) }
    static var trigger: Trigger {
        UserDefaults.standard.string(forKey: DefaultsKeys.appSwitcherTrigger).flatMap(Trigger.init(rawValue:))
            ?? .rightCommand
    }
    static var sameLetterHides: Bool {
        UserDefaults.standard.object(forKey: DefaultsKeys.appSwitcherSameLetterHides) as? Bool ?? true
    }
    static var showsLetters: Bool {
        UserDefaults.standard.object(forKey: DefaultsKeys.appSwitcherShowsLetters) as? Bool ?? true
    }
    /// The letters an app can be given, in order.
    nonisolated static let alphabet = (UnicodeScalar("a").value...UnicodeScalar("z").value)
        .compactMap(UnicodeScalar.init).map { String(Character($0)) }
    /// How long a notice stays in the notch.
    static let noticeLifetime: TimeInterval = 1.8
    /// How long the key is held alone before the letters show.
    static let lettersDelay: Duration = .milliseconds(450)

    /// Letters given to apps, lowercased, to bundle identifiers.
    @Published private(set) var assignments: [String: String]
    /// Apps the switcher leaves alone while they are in front, by bundle identifier.
    @Published private(set) var ignoredApps: [String]
    /// What the notch says after a letter is given, or when a letter has no app.
    @Published private(set) var notice: NotchHome.Notice?
    @Published private(set) var isTapInstalled = false
    /// What each key types in the current layout with no modifier, by key code: the window
    /// switcher's search.
    private(set) var typedKeys: [Int64: String] = [:]
    /// What each key types in the ASCII-capable layout, by key code: the letters, and the window
    /// switcher's W, M, H and Q, which stay put when a non-Latin layout is selected.
    private(set) var latinKeys: [Int64: String] = [:]

    private let tap = LetterKeyTap()
    /// Bundle identifiers, the most recently active first.
    private var recent: [String] = []
    /// The order a letter walks its apps while the key stays held, so pressing it again and again
    /// reaches every app rather than going back and forth between the two used last.
    private var cycle: (letter: String, ids: [String])?
    private var observers: [NSObjectProtocol] = []
    private var noticeTask: Task<Void, Never>?
    private var lettersTask: Task<Void, Never>?
    private var accessTask: Task<Void, Never>?
    private var started = false
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "AppSwitcher")

    private init() {
        assignments = Self.storedAssignments()
        ignoredApps = UserDefaults.standard.stringArray(forKey: DefaultsKeys.appSwitcherIgnoredApps) ?? []
    }

    /// The letters saved in Settings, leaving out any that are not a–z (set from a non-Latin
    /// layout by an earlier version), which no key could reach.
    private static func storedAssignments() -> [String: String] {
        let saved =
            UserDefaults.standard.dictionary(forKey: DefaultsKeys.appSwitcherLetters) as? [String: String] ?? [:]
        return saved.filter { alphabet.contains($0.key) }
    }

    /// Called at launch and whenever the switches in Settings change.
    func refresh() {
        let wanted = Self.isEnabled && !ProcessIdentity.isTestHost
        if wanted { startWatching() }
        if wanted, !tap.isInstalled {
            tap.install(
                onLetter: { [weak self] letter, assign in
                    Task { @MainActor in self?.press(letter, assign: assign) }
                },
                onSwitcher: { event in
                    Task { @MainActor in WindowSwitcher.shared.handle(event) }
                },
                onHold: { [weak self] event in
                    Task { @MainActor in self?.hold(event) }
                })
            if tap.isInstalled { logger.notice("App switcher tap installed") }
        }
        readLayout()
        tap.setKeys(Self.trigger.keys)
        tap.setEnabled(wanted)
        tap.setSwitcherEnabled(wanted && WindowSwitcher.isEnabled)
        updatePause(frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        isTapInstalled = tap.isInstalled
        watchForAccess(wanted && !tap.isInstalled)
        if !wanted { hideLetters() }
    }

    /// Settings were imported: read the letters and ignored apps again, then the switches.
    func reload() {
        assignments = Self.storedAssignments()
        ignoredApps = UserDefaults.standard.stringArray(forKey: DefaultsKeys.appSwitcherIgnoredApps) ?? []
        refresh()
    }

    /// The window switcher closed: keys go back to the apps.
    func closeWindowSwitcher() {
        tap.closeSwitcher()
    }

    private func readLayout() {
        typedKeys = Self.typedKeys(in: TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue())
        latinKeys = Self.typedKeys(in: TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue())
        tap.setLetters(latinKeys.compactMapValues { Self.letter(of: $0) }.filter { Self.alphabet.contains($0.value) })
    }

    /// Accessibility granted after launch: the tap is installed as soon as it is, without waiting
    /// for Settings to be opened again.
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

    /// Leaves an app chosen in Settings alone: while it is in front its keys all go to it.
    func ignore(appAt url: URL) {
        guard let id = Bundle(url: url)?.bundleIdentifier, !ignoredApps.contains(id) else { return }
        ignoredApps.append(id)
        saveIgnored()
    }

    func stopIgnoring(_ bundleID: String) {
        ignoredApps.removeAll { $0 == bundleID }
        saveIgnored()
    }

    nonisolated static func freeLetter(preferring wanted: String?, in assignments: [String: String]) -> String? {
        if let wanted, alphabet.contains(wanted), assignments[wanted] == nil { return wanted }
        return alphabet.first { assignments[$0] == nil }
    }

    /// The name an app shows: running, installed, or else its bundle identifier.
    static func name(of bundleID: String) -> String {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
            let name = app.localizedName
        {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }

    // MARK: Keys

    private func press(_ letter: String, assign: Bool) {
        hideLetters()
        let frontmost = NSWorkspace.shared.frontmostApplication
        if assign {
            guard let app = frontmost, app.activationPolicy == .regular, let id = app.bundleIdentifier else { return }
            let previous = assignments[letter].flatMap { $0 == id ? nil : Self.name(of: $0) }
            assignments = Self.assigning(letter, to: id, in: assignments)
            save()
            let keys = "\(Self.trigger.short) \(letter.uppercased())"
            show(
                NotchHome.Notice(
                    symbol: "command", title: app.localizedName ?? id,
                    detail: previous.map { String(localized: "\(keys) · was \($0)") } ?? keys))
            return
        }
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
        let apps = running.map { App(id: $0.bundleIdentifier!, name: $0.localizedName ?? "") }
        let order = Self.ordered(
            Self.candidates(for: letter, running: apps, assignments: assignments), letter: letter,
            assignments: assignments, recent: recent)
        let walk: [String]
        if let cycle, cycle.letter == letter, Set(cycle.ids) == Set(order) {
            walk = cycle.ids
        } else {
            walk = order
            cycle = (letter, order)
        }
        let action = Self.action(
            for: letter, frontmost: frontmost?.bundleIdentifier, running: apps, assignments: assignments,
            recent: recent, cycle: walk, sameLetterHides: Self.sameLetterHides)
        switch action {
        case .activate(let id), .launch(let id):
            // Opened as the Dock opens an app: from a background app, macOS can refuse a plain
            // activate, and this also unhides the app and gives it a window when it has none.
            let url =
                running.first(where: { $0.bundleIdentifier == id })?.bundleURL
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            guard let url else {
                show(
                    NotchHome.Notice(
                        symbol: "questionmark.app", title: String(localized: "Can't find \(Self.name(of: id))"),
                        detail: String(localized: "Remove its letter in Settings")))
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        case .hide(let id):
            running.first(where: { $0.bundleIdentifier == id })?.hide()
        case .stay:
            return
        case .nothing:
            show(
                NotchHome.Notice(
                    symbol: "command", title: String(localized: "Nothing on \(letter.uppercased())"),
                    detail: String(
                        localized:
                            "\(Self.trigger.short) \(Self.trigger.assignKey) \(letter.uppercased()) to set one")))
        }
    }

    /// The key held alone shows the letters after a moment; using it for anything, or letting go,
    /// takes them away. Letting go also ends a walk through a letter's apps.
    private func hold(_ event: LetterKeyTap.Hold) {
        switch event {
        case .pressed:
            lettersTask?.cancel()
            guard Self.showsLetters, !WindowSwitcher.shared.isOpen else { return }
            lettersTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.lettersDelay)
                guard let self, !Task.isCancelled, !WindowSwitcher.shared.isOpen else { return }
                LetterSheet.shared.show(self.reaches(), trigger: Self.trigger)
            }
        case .used:
            hideLetters()
        case .released:
            hideLetters()
            cycle = nil
        }
    }

    private func hideLetters() {
        lettersTask?.cancel()
        lettersTask = nil
        LetterSheet.shared.hide()
    }

    /// Every letter that reaches an app now, and that app.
    private func reaches() -> [Reach] {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .map { App(id: $0.bundleIdentifier!, name: $0.localizedName ?? "") }
        return Self.reaches(running: apps, assignments: assignments, recent: recent)
    }

    // MARK: Choosing

    /// The first letter of an app's name, lowercased and without accents; nil when it is not a letter.
    nonisolated static func letter(of name: String) -> String? {
        guard let first = name.trimmingCharacters(in: .whitespaces).first, first.isLetter else { return nil }
        return String(first).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
    }

    /// The apps a letter reaches: the app given the letter, then the running apps whose name
    /// starts with it, by name — leaving out apps given another letter, which answer to that one
    /// instead.
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

    /// The order a letter walks its apps: the app given the letter first, then the others, the
    /// one used most recently first (by name among those not used yet).
    nonisolated static func ordered(
        _ ids: [String], letter: String, assignments: [String: String], recent: [String]
    ) -> [String] {
        let given = assignments[letter].flatMap { ids.contains($0) ? $0 : nil }
        let rank = { (id: String) in recent.firstIndex(of: id) ?? Int.max }
        let rest = ids.enumerated()
            .filter { $0.element != given }
            .sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element)
        return (given.map { [$0] } ?? []) + rest
    }

    /// What a letter does: an app already in front is hidden (or left, as Settings says), or gives
    /// way to the next app with the letter; otherwise the given app, or the one used most
    /// recently, comes forward — launched when it is not running. `cycle` is the order fixed when
    /// the key went down, so repeated presses walk every app.
    nonisolated static func action(
        for letter: String, frontmost: String?, running: [App], assignments: [String: String], recent: [String],
        cycle: [String]? = nil, sameLetterHides: Bool = true
    ) -> Action {
        let ids =
            cycle
            ?? ordered(
                candidates(for: letter, running: running, assignments: assignments), letter: letter,
                assignments: assignments, recent: recent)
        guard let first = ids.first else { return .nothing }
        let runningIDs = Set(running.map(\.id))
        func bring(_ id: String) -> Action { runningIDs.contains(id) ? .activate(id) : .launch(id) }
        if let frontmost, let index = ids.firstIndex(of: frontmost) {
            if ids.count == 1 { return sameLetterHides ? .hide(frontmost) : .stay }
            return bring(ids[(index + 1) % ids.count])
        }
        return bring(first)
    }

    /// Every letter that reaches an app, in order, with the app it brings forward first.
    nonisolated static func reaches(running: [App], assignments: [String: String], recent: [String]) -> [Reach] {
        alphabet.compactMap { letter in
            let ids = ordered(
                candidates(for: letter, running: running, assignments: assignments), letter: letter,
                assignments: assignments, recent: recent)
            guard let first = ids.first else { return nil }
            return Reach(letter: letter, id: first, assigned: assignments[letter] == first)
        }
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

    private func saveIgnored() {
        UserDefaults.standard.set(ignoredApps, forKey: DefaultsKeys.appSwitcherIgnoredApps)
        updatePause(frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    private func updatePause(frontmost: String?) {
        tap.setPaused(frontmost.map(ignoredApps.contains) ?? false)
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
                    self.updatePause(frontmost: id)
                }
            })
        observers.append(
            DistributedNotificationCenter.default().addObserver(
                forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.readLayout() }
            })
    }

    /// The character each key types in a layout with no modifier, by key code, lowercased. Read
    /// here, on the main thread, since the layout calls are not safe on the tap's thread.
    static func typedKeys(in source: TISInputSource?) -> [Int64: String] {
        guard let source, let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
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
                let text = String(utf16CodeUnits: characters, count: length).lowercased()
                guard let scalar = text.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar),
                    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { continue }
                letters[Int64(code)] = text
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

    /// The trigger on its own: pressed, then used with a key, a click or another modifier, then
    /// let go. Sent while the switcher is on and the app in front is not left alone.
    enum Hold: Equatable {
        case pressed
        case used
        case released
    }

    private let lock = NSLock()
    private var port: CFMachPort?
    private var enabled = false
    /// The app in front is one the switcher leaves alone.
    private var paused = false
    private var keys = AppSwitcher.Trigger.rightCommand.keys
    private var letters: [Int64: String] = [:]
    /// Key codes whose press was taken, so their release is taken too.
    private var taken = Set<Int64>()
    private var onLetter: ((String, Bool) -> Void)?
    private var switcherEnabled = false
    /// The window switcher is showing: every key goes to it until the trigger is let go.
    private var switcherOpen = false
    private var onSwitcher: ((WindowSwitcher.Event) -> Void)?
    private var onHold: ((Hold) -> Void)?
    /// The trigger is down, and whether it has been used for something since.
    private var triggerHeld = false
    private var holdUsed = false

    var isInstalled: Bool { lock.withLock { port != nil } }

    func setEnabled(_ on: Bool) { lock.withLock { enabled = on } }
    func setPaused(_ on: Bool) { lock.withLock { paused = on } }
    func setLetters(_ map: [Int64: String]) { lock.withLock { letters = map } }
    func setKeys(_ keys: Keys) { lock.withLock { self.keys = keys } }
    func setSwitcherEnabled(_ on: Bool) { lock.withLock { switcherEnabled = on } }
    func closeSwitcher() { lock.withLock { switcherOpen = false } }

    /// `onLetter` gets the letter and whether the assign key was held (giving the letter), once
    /// per press; repeats are taken but not passed on.
    /// `onSwitcher` gets the window switcher's opening (trigger and Tab), every key while it
    /// shows, and the trigger let go.
    /// `onHold` follows the trigger held on its own (see `Hold`).
    func install(
        onLetter: @escaping (String, Bool) -> Void, onSwitcher: @escaping (WindowSwitcher.Event) -> Void,
        onHold: @escaping (Hold) -> Void
    ) {
        guard !isInstalled else { return }
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<LetterKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
            return tap.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
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
            self.onSwitcher = onSwitcher
            self.onHold = onHold
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
        let flags = event.flags
        if type == .flagsChanged {
            // Letting go of the trigger picks the window; the modifier itself goes on as usual.
            let (released, hold) = lock.withLock { () -> (Bool, Hold?) in
                let hold = holdChange(flags: flags.rawValue)
                guard switcherOpen, flags.rawValue & keys.trigger == 0 else { return (false, hold) }
                switcherOpen = false
                return (true, hold)
            }
            if released { lock.withLock({ onSwitcher })?(.release) }
            if let hold { lock.withLock({ onHold })?(hold) }
            return false
        }
        if type != .keyDown, type != .keyUp {
            // A click or scroll with the trigger held is a ⌘-click, not a wait for the letters.
            if let hold = lock.withLock({ markUsed() }) { lock.withLock({ onHold })?(hold) }
            return false
        }
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp {
            return lock.withLock { taken.remove(code) != nil }
        }
        if let hold = lock.withLock({ markUsed() }) { lock.withLock({ onHold })?(hold) }
        // The switcher takes every key while it shows, or opens on the trigger and Tab.
        let switcher: WindowSwitcher.Event? = lock.withLock {
            if switcherOpen {
                taken.insert(code)
                return .key(code: code, flags: flags.rawValue)
            }
            guard enabled, !paused, switcherEnabled,
                Self.opensSwitcher(code: code, flags: flags.rawValue, control: flags.contains(.maskControl), keys: keys)
            else { return nil }
            switcherOpen = true
            taken.insert(code)
            return .open(backwards: flags.contains(.maskShift))
        }
        if let switcher {
            lock.withLock({ onSwitcher })?(switcher)
            return true
        }
        let (letters, keys) = lock.withLock { (enabled && !paused ? self.letters : [:], self.keys) }
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

    /// Follows the trigger going down and up, under the lock. Pressed only on its own; another
    /// modifier held with it (or added after) counts as using it.
    private func holdChange(flags: UInt64) -> Hold? {
        let down = flags & keys.trigger != 0
        let others =
            flags & keys.blocked != 0
            || flags & (UInt64(CGEventFlags.maskShift.rawValue) | UInt64(CGEventFlags.maskControl.rawValue)) != 0
        let active = enabled && !paused
        if down, !triggerHeld {
            triggerHeld = true
            holdUsed = others
            return active && !others ? .pressed : nil
        }
        if !down, triggerHeld {
            triggerHeld = false
            holdUsed = false
            return active ? .released : nil
        }
        if down, others, !holdUsed {
            holdUsed = true
            return active ? .used : nil
        }
        return nil
    }

    /// The trigger held is now being used, under the lock: once per hold.
    private func markUsed() -> Hold? {
        guard triggerHeld, !holdUsed else { return nil }
        holdUsed = true
        return enabled && !paused ? .used : nil
    }

    /// Tab with the trigger held, its left-hand twin not, and no Control (Shift goes backwards).
    static func opensSwitcher(code: Int64, flags: UInt64, control: Bool, keys: Keys) -> Bool {
        code == Int64(kVK_Tab) && flags & keys.trigger != 0 && flags & keys.blocked == 0 && !control
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
