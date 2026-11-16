import AppKit
import SwiftUI

/// The Focus Blur page: the switch and the look of the blur, which windows stay sharp, and the
/// apps it never blurs behind, each its own section.
struct FocusBlurSettingsPage: View {
    @AppStorage(DefaultsKeys.focusBlurEnabled) private var enabled = false
    @AppStorage(DefaultsKeys.focusBlurStrength) private var strength = 0.85
    @AppStorage(DefaultsKeys.focusBlurTint) private var tintRaw = FocusBlur.Tint.system.rawValue
    @AppStorage(DefaultsKeys.focusBlurDim) private var dim = 0.15
    @AppStorage(DefaultsKeys.focusBlurGrain) private var grain = false
    @AppStorage(DefaultsKeys.focusBlurAppWide) private var appWide = false
    @AppStorage(DefaultsKeys.focusBlurOtherDisplays) private var otherDisplaysRaw = FocusBlur.OtherDisplays.blur
        .rawValue
    @AppStorage(DefaultsKeys.focusBlurShake) private var shake = false
    @ObservedObject private var focusBlur = FocusBlur.shared
    @State private var settingsSearch = ""

    private var search: SettingsSearchMatcher { SettingsSearchMatcher(query: settingsSearch) }

    private var layout: SettingsPageLayout {
        SettingsPageLayout(sections: [.focusBlur, .focusBlurBehavior, .focusBlurApps])
    }

    private func shows(_ section: SettingsSection) -> Bool { layout.shows(section, for: search) }

    var body: some View {
        SettingsForm(query: $settingsSearch, hasMatches: layout.hasMatches(for: search)) {
            if shows(.focusBlur) { lookSection }
            if shows(.focusBlurBehavior) { behaviorSection }
            if shows(.focusBlurApps) { appsSection }
        }
        .onAppear { focusBlur.refresh() }
    }

    private var lookSection: some View {
        Section {
            Toggle("Blur Every Window but the One in Use", isOn: $enabled)
            slider("Blur", value: $strength, in: 0.2...1)
            Picker("Tint", selection: $tintRaw) {
                ForEach(FocusBlur.Tint.allCases) { tint in
                    Text(verbatim: tint.title).tag(tint.rawValue)
                }
            }
            slider("Dim", value: $dim, in: 0...0.6)
                .disabled(tintRaw == FocusBlur.Tint.none.rawValue)
            Toggle("Film Grain", isOn: $grain)
        } header: {
            Text("Focus Blur")
        } footer: {
            Text(
                "The window you're working in stays sharp and the rest soften behind it. Click a blurred window to bring it forward."
            )
            .settingsCaption()
        }
    }

    private var behaviorSection: some View {
        Section {
            Toggle("Keep the App's Other Windows Sharp", isOn: $appWide)
            Picker("Other Displays", selection: $otherDisplaysRaw) {
                ForEach(FocusBlur.OtherDisplays.allCases) { choice in
                    Text(verbatim: choice.title).tag(choice.rawValue)
                }
            }
            Toggle("Shake the Pointer to Turn On or Off", isOn: $shake)
        } header: {
            Text("Which Windows Stay Sharp")
        } footer: {
            Text(
                "With the app's other windows kept sharp, its windows stacked right behind the front one stay clear too. A shake is a few quick strokes side to side."
            )
            .settingsCaption()
        }
    }

    private var appsSection: some View {
        Section {
            ForEach(focusBlur.ignoredApps, id: \.self) { bundleID in
                ChosenAppRow(
                    bundleID: bundleID, removeHelp: String(localized: "Blur behind this app again"),
                    onRemove: { focusBlur.stopIgnoring(bundleID) })
            }
            HStack {
                Button("Add an App…", action: chooseApp)
                Spacer()
            }
        } header: {
            Text("Never Blur Behind")
        } footer: {
            Text("While one of these is in front, nothing is blurred: for video calls, screen sharing and games.")
                .settingsCaption()
        }
    }

    private func slider(_ title: LocalizedStringKey, value: Binding<Double>, in range: ClosedRange<Double>)
        -> some View
    {
        HStack(spacing: 10) {
            Text(title)
            Slider(value: value, in: range)
        }
    }

    private func chooseApp() {
        for url in ChosenAppRow.chooseApps(prompt: String(localized: "Never Blur")) { focusBlur.ignore(appAt: url) }
    }
}
