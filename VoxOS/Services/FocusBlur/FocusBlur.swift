import AppKit
import ApplicationServices
import os

/// Blurs every window but the one in use: a blurred, tinted sheet on each display, kept in the
/// window order directly below the window in front, so that window (and the menu bar, the Dock and
/// VoxOS's notch above it) stays sharp while everything behind softens. Clicks pass through the
/// sheet, so a blurred window is brought forward by clicking it as usual, and the sheet follows.
///
/// Nothing is blurred while an app chosen in Settings is in front, or while no window is (the
/// desktop). A quick shake of the pointer turns it on or off, when allowed in Settings. Uses
/// only public AppKit and window-list calls, and Accessibility, when granted, to follow a switch
/// between two windows of one app at once rather than at the next check.
@MainActor
final class FocusBlur: ObservableObject {
    static let shared = FocusBlur()

    enum Tint: String, CaseIterable, Identifiable {
        case system
        case dark
        case light
        case none

        var id: String { rawValue }

        var title: String {
            switch self {
            case .system: return String(localized: "Match the System")
            case .dark: return String(localized: "Dark")
            case .light: return String(localized: "Light")
            case .none: return String(localized: "None")
            }
        }
    }

    /// What the other displays do: blur everything, or keep their own front window sharp.
    enum OtherDisplays: String, CaseIterable, Identifiable {
        case blur
        case keepTopWindow

        var id: String { rawValue }

        var title: String {
            switch self {
            case .blur: return String(localized: "Blur Everything")
            case .keepTopWindow: return String(localized: "Keep Their Front Window Sharp")
            }
        }
    }

    struct Settings: Equatable {
        var enabled = false
        var strength = 0.85
        var tint = Tint.system
        var dim = 0.15
        var grain = false
        var appWide = false
        var otherDisplays = OtherDisplays.blur
        var shake = false
        var ignoredApps: Set<String> = []

        static func read(from defaults: UserDefaults = .standard) -> Settings {
            Settings(
                enabled: defaults.bool(forKey: DefaultsKeys.focusBlurEnabled),
                strength: defaults.double(forKey: DefaultsKeys.focusBlurStrength),
                tint: defaults.string(forKey: DefaultsKeys.focusBlurTint).flatMap(Tint.init) ?? .system,
                dim: defaults.double(forKey: DefaultsKeys.focusBlurDim),
                grain: defaults.bool(forKey: DefaultsKeys.focusBlurGrain),
                appWide: defaults.bool(forKey: DefaultsKeys.focusBlurAppWide),
                otherDisplays: defaults.string(forKey: DefaultsKeys.focusBlurOtherDisplays).flatMap(
                    OtherDisplays.init) ?? .blur,
                shake: defaults.bool(forKey: DefaultsKeys.focusBlurShake),
                ignoredApps: Set(defaults.stringArray(forKey: DefaultsKeys.focusBlurIgnoredApps) ?? []))
        }
    }

    /// A window on screen, as the window list gives it (front to back).
    struct WindowInfo: Equatable {
        let id: CGWindowID
        let pid: pid_t
        /// In the window list's coordinates: origin at the top left of the main display.
        let bounds: CGRect
    }

    /// Where each sheet goes: below which window, by display; nil hides that display's sheet.
    typealias Placement = [CGDirectDisplayID: CGWindowID?]

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.focusBlurEnabled) }

    @Published private(set) var ignoredApps: [String]
    /// Showing on at least one display right now.
    @Published private(set) var isShowing = false

    private var settings = Settings()
    private var sheets: [CGDirectDisplayID: FocusBlurSheet] = [:]
    private var lastPlacement: Placement = [:]
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var axObserver: AXObserver?
    private var axObservedPID: pid_t?
    private let shake = ShakeDetector()
    private var started = false
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "FocusBlur")

    /// How often the front window is checked, for changes no notification reported.
    private static let checkInterval: TimeInterval = 1
    /// Windows smaller than this (palettes, tooltips, status windows) are never the one in use.
    nonisolated static let minimumWindowSide: CGFloat = 80

    private init() {
        ignoredApps = UserDefaults.standard.stringArray(forKey: DefaultsKeys.focusBlurIgnoredApps) ?? []
    }

    /// Called at launch, and again by itself whenever a setting changes.
    func refresh() {
        startWatchingSettings()
        let next = Settings.read()
        let apps = UserDefaults.standard.stringArray(forKey: DefaultsKeys.focusBlurIgnoredApps) ?? []
        if apps != ignoredApps { ignoredApps = apps }
        guard next != settings else { return }
        let wasEnabled = settings.enabled
        settings = next
        guard !ProcessIdentity.isTestHost else { return }
        updateShake()
        if next.enabled {
            if !wasEnabled { start() }
            sheets.values.forEach { $0.apply(next) }
            update(force: true)
        } else if wasEnabled {
            stop()
        }
    }

    /// The menu bar and the shake gesture.
    func toggle() {
        UserDefaults.standard.set(!settings.enabled, forKey: DefaultsKeys.focusBlurEnabled)
        refresh()
    }

    func ignore(appAt url: URL) {
        guard let id = Bundle(url: url)?.bundleIdentifier, !ignoredApps.contains(id) else { return }
        UserDefaults.standard.set(ignoredApps + [id], forKey: DefaultsKeys.focusBlurIgnoredApps)
        refresh()
    }

    func stopIgnoring(_ bundleID: String) {
        UserDefaults.standard.set(ignoredApps.filter { $0 != bundleID }, forKey: DefaultsKeys.focusBlurIgnoredApps)
        refresh()
    }

    // MARK: Running

    private func start() {
        rebuildSheets()
        let workspace = NSWorkspace.shared.notificationCenter
        let center = NotificationCenter.default
        workspaceObservers = [
            workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.frontAppChanged() }
            },
            // A new Space has its own window order: place the sheets again even where the front
            // window is the same.
            workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.update(force: true) }
            },
            workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.update() }
            },
        ]
        observers.append(
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.rebuildSheets()
                    self?.update()
                }
            })
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        timer?.tolerance = 0.3
        frontAppChanged()
        logger.notice("Focus blur on")
    }

    private func stop() {
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceObservers = []
        timer?.invalidate()
        timer = nil
        stopObservingAX()
        let leaving = sheets
        sheets = [:]
        lastPlacement = [:]
        isShowing = false
        leaving.values.forEach { sheet in sheet.fadeOut { sheet.close() } }
        logger.notice("Focus blur off")
    }

    private func startWatchingSettings() {
        guard !started else { return }
        started = true
        observers.append(
            NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
    }

    private func rebuildSheets() {
        let screens = NSScreen.screens.compactMap { screen in screen.displayID.map { ($0, screen) } }
        let wanted = Set(screens.map(\.0))
        for (id, sheet) in sheets where !wanted.contains(id) {
            sheet.close()
            sheets[id] = nil
        }
        for (id, screen) in screens {
            if let sheet = sheets[id] {
                sheet.setFrame(screen.frame, display: false)
            } else {
                let sheet = FocusBlurSheet(screen: screen)
                sheet.apply(settings)
                sheets[id] = sheet
            }
        }
        lastPlacement = [:]
    }

    private func frontAppChanged() {
        observeAX(NSWorkspace.shared.frontmostApplication?.processIdentifier)
        update()
    }

    /// Puts each sheet below the window it should be under, or hides it. Unless `force`d, a sheet
    /// is moved only when where it belongs has changed.
    func update(force: Bool = false) {
        guard settings.enabled, !sheets.isEmpty else { return }
        if force { lastPlacement = [:] }
        let front = NSWorkspace.shared.frontmostApplication
        let mine = Set(sheets.values.map { CGWindowID($0.windowNumber) })
        let windows = Self.onScreenWindows(excluding: mine)
        let displays = sheets.keys.compactMap { id in NSScreen.screen(for: id).map { (id, $0.cgFrame) } }
        let placement = Self.placement(
            windows: windows, frontPID: front?.processIdentifier,
            frontIgnored: front?.bundleIdentifier.map { settings.ignoredApps.contains($0) } ?? false,
            displays: Dictionary(uniqueKeysWithValues: displays), appWide: settings.appWide,
            otherDisplays: settings.otherDisplays)
        guard placement != lastPlacement else { return }
        lastPlacement = placement
        var showing = false
        for (id, sheet) in sheets {
            if let below = placement[id] ?? nil {
                sheet.order(.below, relativeTo: Int(below))
                sheet.fadeIn()
                showing = true
            } else {
                sheet.fadeOut(then: nil)
            }
        }
        isShowing = showing
    }

    // MARK: Deciding

    /// The normal windows on screen, front to back, leaving out VoxOS's own sheets, windows that
    /// cannot be seen and windows too small to be the one in use.
    static func onScreenWindows(excluding mine: Set<CGWindowID>) -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID, !mine.contains(id),
                (info[kCGWindowLayer as String] as? Int) == 0,
                (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                let boundsInfo = info[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsInfo),
                bounds.width >= minimumWindowSide, bounds.height >= minimumWindowSide
            else { return nil }
            return WindowInfo(id: id, pid: pid, bounds: bounds)
        }
    }

    /// Below which window each display's sheet goes.
    ///
    /// The front app's front window stays sharp on every display; with `appWide`, so do the
    /// app's windows stacked directly behind it. With `.keepTopWindow`, a display the front window
    /// is not on keeps its own front window sharp too. Nothing is blurred while the front app is
    /// ignored or has no window.
    nonisolated static func placement(
        windows: [WindowInfo], frontPID: pid_t?, frontIgnored: Bool, displays: [CGDirectDisplayID: CGRect],
        appWide: Bool, otherDisplays: OtherDisplays
    ) -> Placement {
        let hidden = Placement(uniqueKeysWithValues: displays.keys.map { ($0, nil) })
        guard let frontPID, !frontIgnored,
            let frontIndex = windows.firstIndex(where: { $0.pid == frontPID })
        else { return hidden }
        // With `appWide`, the run of the app's windows from its front one down to the first
        // window of another app.
        var lastSharp = frontIndex
        if appWide {
            while lastSharp + 1 < windows.count, windows[lastSharp + 1].pid == frontPID { lastSharp += 1 }
        }
        let focused = windows[frontIndex]
        let below = windows[lastSharp].id
        var placement = Placement()
        for (display, frame) in displays {
            if otherDisplays == .keepTopWindow, !frame.intersects(focused.bounds),
                let top = windows.first(where: { display == Self.display(of: $0.bounds, in: displays) })
            {
                placement[display] = top.id
            } else {
                placement[display] = below
            }
        }
        return placement
    }

    /// The display holding most of `bounds`.
    nonisolated static func display(of bounds: CGRect, in displays: [CGDirectDisplayID: CGRect])
        -> CGDirectDisplayID?
    {
        displays.max { lhs, rhs in
            lhs.value.intersection(bounds).area < rhs.value.intersection(bounds).area
        }.flatMap { $0.value.intersects(bounds) ? $0.key : nil }
    }

    // MARK: Following window switches within an app

    /// Watches the front app for a new focused window, so switching windows within it (⌘`, a
    /// click) moves the sheet at once rather than at the next check.
    private func observeAX(_ pid: pid_t?) {
        guard pid != axObservedPID else { return }
        stopObservingAX()
        guard let pid, pid != getpid(), AXIsProcessTrusted() else { return }
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let blur = Unmanaged<FocusBlur>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { blur.update() } }
        }
        var observer: AXObserver?
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [
            kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification, kAXWindowCreatedNotification,
            kAXWindowMiniaturizedNotification,
        ] {
            AXObserverAddNotification(observer, app, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        axObserver = observer
        axObservedPID = pid
    }

    private func stopObservingAX() {
        if let axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(axObserver), .defaultMode)
        }
        axObserver = nil
        axObservedPID = nil
    }

    // MARK: Shake

    private func updateShake() {
        if settings.shake {
            shake.start { [weak self] in self?.toggle() }
        } else {
            shake.stop()
        }
    }
}

// MARK: - The sheet

/// One display's blurred sheet: a window as large as the display that blurs what is behind it,
/// with a tint and, if asked for, a little grain. It never takes a click or the keyboard.
final class FocusBlurSheet: NSPanel {
    private let blur = NSVisualEffectView()
    private let tintLayer = CALayer()
    private let grainLayer = CALayer()
    private var shown = false

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
            defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .normal
        // On every Space, left out of ⌘-Tab, Mission Control and the window cycle.
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        animationBehavior = .none
        alphaValue = 0

        let content = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        content.wantsLayer = true
        content.autoresizingMask = [.width, .height]
        blur.frame = content.bounds
        blur.autoresizingMask = [.width, .height]
        blur.blendingMode = .behindWindow
        blur.material = .fullScreenUI
        blur.state = .active
        content.addSubview(blur)
        let overlay = NSView(frame: content.bounds)
        overlay.wantsLayer = true
        overlay.autoresizingMask = [.width, .height]
        tintLayer.frame = overlay.bounds
        tintLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        grainLayer.frame = overlay.bounds
        grainLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        grainLayer.backgroundColor = Self.grainPattern
        overlay.layer?.addSublayer(tintLayer)
        overlay.layer?.addSublayer(grainLayer)
        content.addSubview(overlay)
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    @MainActor
    func apply(_ settings: FocusBlur.Settings) {
        blur.alphaValue = CGFloat(min(max(settings.strength, 0.1), 1))
        switch settings.tint {
        case .system:
            blur.appearance = nil
            tintLayer.backgroundColor = NSColor.black.cgColor
            tintLayer.opacity = Float(settings.dim) * (NSApp.effectiveAppearance.isDark ? 1 : 0.5)
        case .dark:
            blur.appearance = NSAppearance(named: .darkAqua)
            tintLayer.backgroundColor = NSColor.black.cgColor
            tintLayer.opacity = Float(settings.dim)
        case .light:
            blur.appearance = NSAppearance(named: .aqua)
            tintLayer.backgroundColor = NSColor.white.cgColor
            tintLayer.opacity = Float(settings.dim)
        case .none:
            blur.appearance = nil
            tintLayer.opacity = 0
        }
        grainLayer.opacity = settings.grain ? 0.07 : 0
    }

    @MainActor
    func fadeIn() {
        guard !shown else { return }
        shown = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            animator().alphaValue = 1
        }
    }

    @MainActor
    func fadeOut(then done: (() -> Void)?) {
        guard shown else {
            done?()
            return
        }
        shown = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            animator().alphaValue = 0
        } completionHandler: {
            done?()
        }
    }

    @MainActor
    private static var fadeDuration: TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
    }

    /// A tile of fine noise, repeated across the sheet.
    private static let grainPattern: CGColor? = {
        let side = 128
        var rng = SplitMix(seed: 42)
        let pixels = (0..<side * side).map { _ in UInt8(rng.nextUnit() * 255) }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
            let image = CGImage(
                width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return NSColor(patternImage: NSImage(cgImage: image, size: NSSize(width: side, height: side))).cgColor
    }()
}

// MARK: - Shake to toggle

/// A quick side-to-side shake of the pointer: four or more changes of direction, each a real
/// stroke, within a moment.
@MainActor
final class ShakeDetector {
    private var monitor: Any?
    private var onShake: (() -> Void)?
    private var state = ShakeState()

    func start(onShake: @escaping () -> Void) {
        self.onShake = onShake
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated { self?.moved(event.deltaX, at: event.timestamp) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        state = ShakeState()
    }

    private func moved(_ dx: CGFloat, at time: TimeInterval) {
        if state.add(dx: dx, at: time) { onShake?() }
    }
}

/// The shake's arithmetic, apart from the event monitor so it can be tested.
struct ShakeState {
    static let strokeLength: CGFloat = 60
    static let reversals = 4
    static let window: TimeInterval = 0.8
    static let cooldown: TimeInterval = 1.2

    private var direction: CGFloat = 0
    private var stroke: CGFloat = 0
    private var turns: [TimeInterval] = []
    private var lastFired: TimeInterval = -.infinity

    /// Adds a movement; true when it completes a shake.
    mutating func add(dx: CGFloat, at time: TimeInterval) -> Bool {
        guard dx != 0 else { return false }
        let sign: CGFloat = dx > 0 ? 1 : -1
        if sign == direction {
            stroke += abs(dx)
            return false
        }
        // A change of direction counts only after a real stroke the other way.
        if direction != 0, stroke >= Self.strokeLength { turns.append(time) }
        direction = sign
        stroke = abs(dx)
        turns.removeAll { time - $0 > Self.window }
        guard turns.count >= Self.reversals, time - lastFired > Self.cooldown else { return false }
        turns.removeAll()
        lastFired = time
        return true
    }
}

// MARK: - Helpers

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map {
            CGDirectDisplayID($0.uint32Value)
        }
    }

    static func screen(for id: CGDirectDisplayID) -> NSScreen? {
        screens.first { $0.displayID == id }
    }

    /// The frame in the window list's coordinates: origin at the top left of the main display.
    var cgFrame: CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? frame.height
        return CGRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
    }
}

extension CGRect {
    fileprivate var area: CGFloat { isNull ? 0 : width * height }
}

extension NSAppearance {
    fileprivate var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}
