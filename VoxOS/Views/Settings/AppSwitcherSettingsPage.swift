import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The App Switcher page: the switch and the key it listens to, the letters given to apps, the
/// window switcher, and the apps it leaves alone, each its own section.
struct AppSwitcherSettingsPage: View {
    @AppStorage(DefaultsKeys.appSwitcherEnabled) private var enabled = false
    @AppStorage(DefaultsKeys.appSwitcherTrigger) private var triggerRaw = AppSwitcher.Trigger.rightCommand.rawValue
    @AppStorage(DefaultsKeys.windowSwitcherEnabled) private var windowSwitcher = true
    @AppStorage(DefaultsKeys.appSwitcherSameLetterHides) private var sameLetterHides = true
    @AppStorage(DefaultsKeys.appSwitcherShowsLetters) private var showsLetters = true
    @ObservedObject private var switcher = AppSwitcher.shared
    @State private var settingsSearch = ""

    private var search: SettingsSearchMatcher { SettingsSearchMatcher(query: settingsSearch) }

    private var trigger: AppSwitcher.Trigger { AppSwitcher.Trigger(rawValue: triggerRaw) ?? .rightCommand }

    var body: some View {
        SettingsForm(query: $settingsSearch, hasMatches: search.matchesAny([.appSwitcher])) {
            if search.matches(.appSwitcher) {
                switchSection
                if enabled {
                    lettersSection
                    windowsSection
                    leftAloneSection
                }
            }
        }
        .onAppear { switcher.refresh() }
    }

    private var switchSection: some View {
        Section {
            Toggle("Switch Apps with a Key and a Letter", isOn: $enabled)
                .onChange(of: enabled) { _, _ in switcher.refresh() }
            if enabled {
                Picker("Key to Hold", selection: $triggerRaw) {
                    ForEach(AppSwitcher.Trigger.allCases) { trigger in
                        Text(verbatim: trigger.title).tag(trigger.rawValue)
                    }
                }
                .onChange(of: triggerRaw) { _, _ in switcher.refresh() }
                if !switcher.isTapInstalled {
                    HStack {
                        Label("Needs Accessibility to see the keys", systemImage: "exclamationmark.triangle.fill")
                            .font(.app(.caption))
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Open Accessibility Settings", action: openAccessibility)
                            .controlSize(.small)
                    }
                }
            }
        } header: {
            Text("App Switcher")
        } footer: {
            caption(
                "Hold \(trigger.short) and press the first letter of an app's name to bring it forward. An app that isn't running is opened."
            )
        }
    }

    private var lettersSection: some View {
        Section {
            Picker("Same Letter Again", selection: $sameLetterHides) {
                Text("Hides the App").tag(true)
                Text("Does Nothing").tag(false)
            }
            Toggle("Show Letters While Holding \(trigger.short)", isOn: $showsLetters)
            ForEach(switcher.assignments.sorted { $0.key < $1.key }, id: \.key) { letter, bundleID in
                AppSwitcherLetterRow(
                    letter: letter, bundleID: bundleID, taken: switcher.assignments,
                    onChange: { switcher.assign($0, to: bundleID) },
                    onRemove: { switcher.removeAssignment(letter) })
            }
            HStack {
                Button("Add App…", action: chooseApp)
                    .disabled(switcher.assignments.count >= AppSwitcher.alphabet.count)
                Spacer()
            }
        } header: {
            Text("Letters")
        } footer: {
            caption(
                "An app listed here keeps its letter; every other app is reached by its first letter. When apps share a letter, pressing it again moves to the next one. \(trigger.short) \(trigger.assignKey) and a letter gives the app in front that letter."
            )
        }
    }

    private var windowsSection: some View {
        Section {
            Toggle("Show Windows with \(trigger.short) Tab", isOn: $windowSwitcher)
                .onChange(of: windowSwitcher) { _, _ in switcher.refresh() }
            if windowSwitcher, !CGPreflightScreenCaptureAccess() {
                Text(
                    "Allow Screen Recording to see window titles and thumbnails; without it each window shows its app."
                )
                .font(.app(.caption))
                .foregroundStyle(.secondary)
            }
        } header: {
            Text("Window Switcher")
        } footer: {
            caption(
                "Shows this Space's windows, then minimized and hidden ones. Tab and the arrows move, letting go switches. W closes, M minimizes, H hides, Q twice quits and / searches."
            )
        }
    }

    private var leftAloneSection: some View {
        Section {
            ForEach(switcher.ignoredApps, id: \.self) { bundleID in
                AppSwitcherIgnoredRow(bundleID: bundleID, onRemove: { switcher.stopIgnoring(bundleID) })
            }
            HStack {
                Button("Leave an App Alone…", action: chooseIgnoredApp)
                Spacer()
            }
        } header: {
            Text("Apps Left Alone")
        } footer: {
            caption(
                "While one of these is in front, \(trigger.short) and a letter go to it, for games, virtual machines and remote desktops."
            )
        }
    }

    private func caption(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.app(.caption))
            .foregroundStyle(.secondary)
    }

    private func chooseApp() {
        for url in Self.chooseApps(prompt: String(localized: "Add")) { switcher.add(appAt: url) }
    }

    private func chooseIgnoredApp() {
        for url in Self.chooseApps(prompt: String(localized: "Leave Alone")) { switcher.ignore(appAt: url) }
    }

    private static func chooseApps(prompt: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Apps")
        panel.prompt = prompt
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        guard panel.runModal() == .OK else { return [] }
        return panel.urls
    }

    private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// An app the switcher leaves alone: its icon and name, and a way to stop.
private struct AppSwitcherIgnoredRow: View {
    let bundleID: String
    let onRemove: () -> Void

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 10) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 18, height: 18)
            }
            Text(verbatim: url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Stop leaving this app alone")
            .accessibilityLabel(Text("Stop leaving this app alone"))
        }
    }
}

/// A letter given to an app: the letter (changed from a menu), the app's icon and name, and a way
/// to take the letter off.
private struct AppSwitcherLetterRow: View {
    let letter: String
    let bundleID: String
    let taken: [String: String]
    let onChange: (String) -> Void
    let onRemove: () -> Void

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 10) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 18, height: 18)
            }
            Text(verbatim: url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID)
                .lineLimit(1)
            if url == nil {
                Text("Not installed")
                    .font(.app(.caption))
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 8)
            Picker(
                "Letter",
                selection: Binding(get: { letter }, set: { if $0 != letter { onChange($0) } })
            ) {
                ForEach(AppSwitcher.alphabet, id: \.self) { candidate in
                    // A letter held by another app is offered too: choosing it moves it here.
                    let holder = taken[candidate].flatMap { $0 == bundleID ? nil : Self.name(of: $0) }
                    Text(verbatim: holder.map { "\(candidate.uppercased())  —  \($0)" } ?? candidate.uppercased())
                        .tag(candidate)
                }
            }
            .labelsHidden()
            .fixedSize()
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove this letter")
            .accessibilityLabel(Text("Remove the letter \(letter.uppercased())"))
        }
    }

    private static func name(of bundleID: String) -> String? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path) }
    }
}
