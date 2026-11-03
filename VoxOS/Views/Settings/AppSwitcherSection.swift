import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings for the app switcher: the switch, the key held with a letter, and the letters given
/// to apps — added, changed and removed here as well as from the keyboard.
struct AppSwitcherSection: View {
    @AppStorage(DefaultsKeys.appSwitcherEnabled) private var enabled = false
    @AppStorage(DefaultsKeys.appSwitcherTrigger) private var triggerRaw = AppSwitcher.Trigger.rightCommand.rawValue
    @ObservedObject private var switcher = AppSwitcher.shared

    private var trigger: AppSwitcher.Trigger { AppSwitcher.Trigger(rawValue: triggerRaw) ?? .rightCommand }

    var body: some View {
        Section("App Switcher") {
            Toggle("Switch apps with a key and a letter", isOn: $enabled)
                .onChange(of: enabled) { _, _ in switcher.refresh() }
            if enabled {
                Picker("Hold", selection: $triggerRaw) {
                    ForEach(AppSwitcher.Trigger.allCases) { trigger in
                        Text(verbatim: trigger.title).tag(trigger.rawValue)
                    }
                }
                .onChange(of: triggerRaw) { _, _ in switcher.refresh() }
                if !switcher.isTapInstalled {
                    Label("Needs Accessibility to see the keys", systemImage: "exclamationmark.triangle.fill")
                        .font(.app(.caption))
                        .foregroundStyle(.orange)
                }
            }
            Text(
                "Hold \(trigger.short) and press the first letter of an app's name to bring it forward. Press the same letter again to hide it, or to move on to the next app with that letter. \(trigger.short) \(trigger.assignKey) and a letter gives the app in front that letter. An app with a letter is launched when it is not running."
            )
            .font(.app(.caption))
            .foregroundStyle(.secondary)

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
        }
        .onAppear { switcher.refresh() }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Apps")
        panel.prompt = String(localized: "Add")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .applicationDirectory, in: .localDomainMask).first
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { switcher.add(appAt: url) }
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
