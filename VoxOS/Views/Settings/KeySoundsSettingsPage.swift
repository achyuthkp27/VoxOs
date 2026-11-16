import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Key Sounds page: the switch, the sound and how loud, how keys sound, and the apps it stays
/// quiet in, each its own section.
struct KeySoundsSettingsPage: View {
    @AppStorage(DefaultsKeys.keySoundsEnabled) private var enabled = false
    @AppStorage(DefaultsKeys.keySoundsProfile) private var profileRaw = KeySoundSynth.Profile.bucklingSpring.rawValue
    @AppStorage(DefaultsKeys.keySoundsVolume) private var volume = 0.6
    @AppStorage(DefaultsKeys.keySoundsKeyUp) private var keyUp = true
    @AppStorage(DefaultsKeys.keySoundsStereo) private var stereo = true
    @AppStorage(DefaultsKeys.keySoundsVaryPitch) private var varyPitch = true
    @AppStorage(DefaultsKeys.keySoundsQuietWhileMicrophone) private var quietWhileMicrophone = true
    @ObservedObject private var keySounds = KeySounds.shared
    @State private var settingsSearch = ""

    private var search: SettingsSearchMatcher { SettingsSearchMatcher(query: settingsSearch) }

    private var profile: KeySoundSynth.Profile { KeySoundSynth.Profile(rawValue: profileRaw) ?? .bucklingSpring }

    /// How keys sound and the quiet apps show only while the switch is on.
    private var layout: SettingsPageLayout {
        SettingsPageLayout(
            sections: [.keySounds, .keySoundsBehavior, .keySoundsQuietApps],
            dependents: [.keySoundsBehavior, .keySoundsQuietApps], on: .keySounds, isOn: enabled)
    }

    private func shows(_ section: SettingsSection) -> Bool { layout.shows(section, for: search) }

    var body: some View {
        SettingsForm(query: $settingsSearch, hasMatches: layout.hasMatches(for: search)) {
            if shows(.keySounds) { switchSection }
            if shows(.keySoundsBehavior) { behaviorSection }
            if shows(.keySoundsQuietApps) { quietAppsSection }
        }
        .onAppear { keySounds.refresh() }
    }

    private var switchSection: some View {
        Section {
            Toggle("Play a Sound as You Type", isOn: $enabled)
            HStack {
                Picker("Switch", selection: $profileRaw) {
                    ForEach(KeySoundSynth.Profile.allCases) { profile in
                        Text(verbatim: profile.title).tag(profile.rawValue)
                    }
                }
                Button("Preview") { keySounds.preview(profile) }
                    .controlSize(.small)
            }
            HStack(spacing: 10) {
                Text("Volume")
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $volume, in: 0.05...1)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
            }
            if enabled, !keySounds.isTapInstalled {
                HStack {
                    Label("Needs Accessibility to hear the keys", systemImage: "exclamationmark.triangle.fill")
                        .font(.app(.caption))
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Open Accessibility Settings", action: openAccessibility)
                        .controlSize(.small)
                }
            }
        } header: {
            Text("Key Sounds")
        } footer: {
            Text(
                "\(profile.detail) Every sound is made on this Mac, and only keys typed on a keyboard sound. The system volume is the limit."
            )
            .settingsCaption()
        }
    }

    private var behaviorSection: some View {
        Section {
            Toggle("Sound When Keys Are Let Go", isOn: $keyUp)
            Toggle("Place Keys Left and Right", isOn: $stereo)
            Toggle("Vary the Pitch of Each Press", isOn: $varyPitch)
            Toggle("Quiet While the Microphone Is in Use", isOn: $quietWhileMicrophone)
        } header: {
            Text("How Keys Sound")
        } footer: {
            Text(
                "Keys on the left of the keyboard sound from the left speaker, keys on the right from the right. While a call, a recording or a dictation is listening, the keys stay quiet so the clicks aren't picked up."
            )
            .settingsCaption()
        }
    }

    private var quietAppsSection: some View {
        Section {
            ForEach(keySounds.quietApps, id: \.self) { bundleID in
                ChosenAppRow(
                    bundleID: bundleID, removeHelp: String(localized: "Play sounds in this app again"),
                    onRemove: { keySounds.stopQuieting(bundleID) })
            }
            HStack {
                Button("Keep an App Quiet…", action: chooseApp)
                Spacer()
            }
        } header: {
            Text("Quiet Apps")
        } footer: {
            Text("While one of these is in front, typing makes no sound: for games, music apps and screen recorders.")
                .settingsCaption()
        }
    }

    private func chooseApp() {
        for url in ChosenAppRow.chooseApps(prompt: String(localized: "Keep Quiet")) { keySounds.quiet(appAt: url) }
    }

    private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// An app chosen in a settings list: its icon and name, and a way to take it off the list.
struct ChosenAppRow: View {
    let bundleID: String
    let removeHelp: String
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
            .help(removeHelp)
            .accessibilityLabel(Text(verbatim: removeHelp))
        }
    }

    /// Asks for one or more apps from /Applications.
    static func chooseApps(prompt: String) -> [URL] {
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
}
