import AppKit
import ApplicationServices
import os

/// macOS's notification banners, said again in the notch as they arrive: the app, the title and
/// the start of the message, for a few seconds.
///
/// Read through Accessibility from Notification Center's own banners, which macOS 26 lays out as
/// a group (subrole `AXNotificationCenterBanner`) with a unique identifier, a description of
/// "App, Title, Subtitle, Body", and title, subtitle and body texts. Nothing is polled: the
/// banners are read when Notification Center reports a change. A banner already on screen when
/// this starts, and the list shown while Notification Center itself is open, are never said.
/// macOS's own banner still shows. Off until switched on.
@MainActor
final class NotchNotifications: ObservableObject {
    static let shared = NotchNotifications()

    struct Banner: Equatable {
        let id: String
        let app: String
        let title: String
        let body: String
    }

    static let bundleID = "com.apple.notificationcenterui"
    /// How long a banner stays in the notch.
    static let lifetime: TimeInterval = 4
    /// More banners than this at once is Notification Center's open list, not new arrivals.
    nonisolated static let maxBannersAtOnce = 3

    @Published private(set) var notice: NotchHome.Notice?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.notchNotificationsEnabled) }

    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var seen: [String] = []
    private var primed = false
    private var scanTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    private var launchObserver: NSObjectProtocol?
    private var started = false
    private let logger = Logger(subsystem: "com.achyuthkp.voxos", category: "NotchNotifications")

    private init() {}

    func start() {
        guard !started, !ProcessIdentity.isTestHost else { return }
        started = true
        attach()
        // Notification Center restarts now and then; the observer goes with it.
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == Self.bundleID else { return }
            MainActor.assumeIsolated { self?.attach() }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        detach()
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        launchObserver = nil
        notice = nil
    }

    private func attach() {
        detach()
        guard AXIsProcessTrusted(),
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first
        else { return }
        let pid = app.processIdentifier
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<NotchNotifications>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { me.scheduleScan() } }
        }
        var created: AXObserver?
        guard AXObserverCreate(pid, callback, &created) == .success, let created else { return }
        let element = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in [kAXWindowCreatedNotification, kAXCreatedNotification, kAXLayoutChangedNotification] {
            AXObserverAddNotification(created, element, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        observer = created
        observedPID = pid
        primed = false
        scheduleScan()
        logger.notice("Watching notification banners")
    }

    private func detach() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = nil
    }

    /// Changes come in bursts as a banner slides in; one read a moment later covers them.
    private func scheduleScan() {
        scanTask?.cancel()
        scanTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.scan()
        }
    }

    private func scan() {
        guard let pid = observedPID else { return }
        let banners = Self.banners(in: AXUIElementCreateApplication(pid))
        let fresh = banners.filter { !seen.contains($0.id) }
        seen.append(contentsOf: fresh.map(\.id))
        if seen.count > 60 { seen.removeFirst(seen.count - 60) }
        // The first read only learns what is already there.
        guard primed else {
            primed = true
            return
        }
        guard banners.count <= Self.maxBannersAtOnce, let newest = fresh.last else { return }
        show(newest)
    }

    private func show(_ banner: Banner) {
        let appID = Self.bundleID(forAppNamed: banner.app)
        notice = NotchHome.Notice(
            symbol: "bell.badge.fill", title: Self.title(of: banner, withIcon: appID != nil),
            detail: banner.body.isEmpty ? nil : banner.body, appIcon: appID)
        clearTask?.cancel()
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.lifetime))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// The band's title. With the app's icon beside it, the notification's own title, as the
    /// band's wing has room for little; without one, the app and the title, or whichever there is.
    nonisolated static func title(of banner: Banner, withIcon: Bool = false) -> String {
        if withIcon, !banner.title.isEmpty { return banner.title }
        switch (banner.app.isEmpty, banner.title.isEmpty) {
        case (false, false): return banner.app == banner.title ? banner.app : "\(banner.app) · \(banner.title)"
        case (false, true): return banner.app
        default: return banner.title
        }
    }

    // MARK: Reading the banners

    private static func banners(in app: AXUIElement) -> [Banner] {
        var found: [Banner] = []
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 8, found.count <= maxBannersAtOnce else { return }
            if string(element, kAXSubroleAttribute) == "AXNotificationCenterBanner" {
                if let banner = banner(from: element) { found.append(banner) }
                return
            }
            for child in children(of: element) { walk(child, depth: depth + 1) }
        }
        for window in children(of: app, attribute: kAXWindowsAttribute) { walk(window, depth: 0) }
        return found
    }

    private static func banner(from group: AXUIElement) -> Banner? {
        var texts: [String: String] = [:]
        for child in children(of: group) where string(child, kAXRoleAttribute) == kAXStaticTextRole {
            if let id = string(child, kAXIdentifierAttribute), let value = string(child, kAXValueAttribute) {
                texts[id] = value
            }
        }
        let id = string(group, kAXIdentifierAttribute) ?? string(group, kAXDescriptionAttribute) ?? ""
        guard !id.isEmpty else { return nil }
        return parse(
            id: id, description: string(group, kAXDescriptionAttribute) ?? "", title: texts["title"] ?? "",
            subtitle: texts["subtitle"] ?? "", body: texts["body"] ?? "")
    }

    /// The app is what the description says before the title ("Mail, Anna, Lunch?, See you at…").
    nonisolated static func parse(id: String, description: String, title: String, subtitle: String, body: String)
        -> Banner?
    {
        guard !title.isEmpty || !body.isEmpty else { return nil }
        var app = ""
        let lead = title.isEmpty ? body : title
        if let range = description.range(of: ", " + lead) {
            app = String(description[..<range.lowerBound])
        } else if let comma = description.firstIndex(of: ",") {
            app = String(description[..<comma])
        }
        let message = [subtitle, body].filter { !$0.isEmpty }.joined(separator: " — ")
        // Without a title, the body leads.
        return Banner(
            id: id, app: app.trimmingCharacters(in: .whitespaces), title: title.isEmpty ? body : title,
            body: title.isEmpty ? subtitle : message)
    }

    /// The app a banner names, running or not (Script Editor posts for scripts without running).
    private static func bundleID(forAppNamed name: String) -> String? {
        guard !name.isEmpty else { return nil }
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == name }) {
            return running.bundleIdentifier
        }
        let fileManager = FileManager.default
        let folders =
            fileManager.urls(for: .applicationDirectory, in: .allDomainsMask)
            + fileManager.urls(for: .applicationDirectory, in: .systemDomainMask).map {
                $0.appendingPathComponent("Utilities")
            }
        for folder in folders {
            let url = folder.appendingPathComponent(name + ".app")
            if fileManager.fileExists(atPath: url.path), let id = Bundle(url: url)?.bundleIdentifier { return id }
        }
        return nil
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func children(of element: AXUIElement, attribute: String = kAXChildrenAttribute)
        -> [AXUIElement]
    {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }
}
