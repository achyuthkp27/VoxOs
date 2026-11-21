import AppKit
import Combine
import SwiftUI

/// Apps chosen to stay out of the way during a Pomodoro focus session: hidden (never quit) when
/// one starts, and hidden again if brought to the front while it runs. Nothing is changed in
/// macOS's own settings, and other devices are left alone. Breaks and the end leave them hidden;
/// they come back when clicked in the Dock, as hidden apps do.
@MainActor
final class NotchFocusApps: ObservableObject {
    static let shared = NotchFocusApps()

    /// Bundle ids of the apps to hide.
    @Published private(set) var chosen: Set<String>

    private var timerWatch: AnyCancellable?
    private var activationWatch: AnyCancellable?
    private var focusing = false
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        chosen = Set(defaults.stringArray(forKey: DefaultsKeys.notchFocusHiddenApps) ?? [])
    }

    func toggle(_ bundleID: String) {
        if chosen.contains(bundleID) { chosen.remove(bundleID) } else { chosen.insert(bundleID) }
        defaults.set(chosen.sorted(), forKey: DefaultsKeys.notchFocusHiddenApps)
        if focusing { hideChosen() }
    }

    /// Follows the timers from launch; costs nothing while no app is chosen.
    func start() {
        guard timerWatch == nil, !ProcessIdentity.isTestHost else { return }
        timerWatch = NotchTimers.shared.$running
            .map { Self.isFocusing($0) }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] focusing in self?.focusChanged(focusing) }
    }

    /// A focus session that is counting down, not paused.
    nonisolated static func isFocusing(_ timer: NotchTimer?) -> Bool {
        timer?.kind == .focus && timer?.isPaused == false
    }

    private func focusChanged(_ focusing: Bool) {
        self.focusing = focusing
        guard focusing, !chosen.isEmpty else {
            activationWatch = nil
            return
        }
        ActivityTrail.mark("focus apps hidden")
        hideChosen()
        activationWatch = NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didActivateApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .receive(on: RunLoop.main)
            .sink { [weak self] app in
                guard let self, let id = app.bundleIdentifier, self.chosen.contains(id) else { return }
                app.hide()
            }
    }

    private func hideChosen() {
        for app in NSWorkspace.shared.runningApplications
        where app.bundleIdentifier.map(chosen.contains) == true && !app.isHidden {
            app.hide()
        }
    }

    /// Apps that can be picked: those running with a Dock icon, and those chosen already.
    func candidates() -> [(id: String, name: String)] {
        let me = Bundle.main.bundleIdentifier
        var found: [String: String] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != me else { continue }
            found[id] = app.localizedName ?? id
        }
        for id in chosen where found[id] == nil { found[id] = NotchHomeApp.name(for: id) ?? id }
        return found.map { (id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// "Hide During Focus", in the Pomodoro face's menu: a tick per app.
struct NotchFocusAppsMenu: View {
    @ObservedObject var apps: NotchFocusApps

    var body: some View {
        Menu("Hide During Focus") {
            ForEach(apps.candidates(), id: \.id) { app in
                Toggle(
                    app.name,
                    isOn: Binding(get: { apps.chosen.contains(app.id) }, set: { _ in apps.toggle(app.id) }))
            }
        }
    }
}
