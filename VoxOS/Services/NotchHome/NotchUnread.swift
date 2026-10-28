import AppKit
import ApplicationServices
import Combine

/// A passing notice when an app's unread count goes up: Mail, Messages, or any app with a badge
/// in the Dock.
///
/// The Dock already knows every badge; its accessibility tree gives each item's count
/// (AXStatusLabel), with the Accessibility access VoxOS has for its shortcuts. Read once a minute
/// with slack, not while the displays sleep; a count that only went down says nothing.
@MainActor
final class NotchUnread: ObservableObject {
    static let shared = NotchUnread()

    static let interval: TimeInterval = 60
    static let noticeLifetime: TimeInterval = 4

    @Published private(set) var notice: NotchHome.Notice?
    private var counts: [String: Int]?
    private var timer: Timer?
    private var awayWatch: AnyCancellable?
    private var clearTask: Task<Void, Never>?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: DefaultsKeys.notchUnreadEnabled) }

    private init() {}

    func start() {
        guard awayWatch == nil, !ProcessIdentity.isTestHost else { return }
        awayWatch = PowerState.shared.$isAway.receive(on: RunLoop.main).sink { [weak self] away in
            self?.schedule(away: away)
        }
    }

    func stop() {
        awayWatch = nil
        timer?.invalidate()
        timer = nil
        counts = nil
    }

    private func schedule(away: Bool) {
        timer?.invalidate()
        timer = nil
        guard !away else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = Self.interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        check()
    }

    private func check() {
        let now = Self.dockBadges()
        defer { counts = now }
        // The first reading is the baseline, not news.
        guard let before = counts, let (app, count) = Self.risen(from: before, to: now) else { return }
        notice = NotchHome.Notice(
            symbol: "envelope.badge.fill", title: app, detail: String(localized: "\(count) unread"))
        clearTask?.cancel()
        clearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.noticeLifetime))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    /// The app whose count rose the most, with its count now.
    nonisolated static func risen(from before: [String: Int], to now: [String: Int]) -> (String, Int)? {
        now.filter { $0.value > (before[$0.key] ?? 0) }
            .max { ($0.value - (before[$0.key] ?? 0)) < ($1.value - (before[$1.key] ?? 0)) }
            .map { ($0.key, $0.value) }
    }

    /// Dock item title to its badge, for items with a numeric badge.
    static func dockBadges() -> [String: Int] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return [:] }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var badges: [String: Int] = [:]
        for list in children(of: app) {
            for item in children(of: list) {
                guard let title = string(item, kAXTitleAttribute), let label = string(item, "AXStatusLabel"),
                    let count = Int(label.filter(\.isNumber)), count > 0
                else { continue }
                badges[title] = count
            }
        }
        return badges
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else {
            return []
        }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
