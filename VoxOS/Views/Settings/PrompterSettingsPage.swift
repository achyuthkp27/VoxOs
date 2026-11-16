import AppKit
import SwiftUI

/// The Voice Prompter page: the script and the button that shows the prompter, then how the
/// prompter looks.
struct PrompterSettingsPage: View {
    @AppStorage(DefaultsKeys.prompterFontSize) private var fontSize = 24.0
    @AppStorage(DefaultsKeys.prompterLines) private var lines = 4
    @AppStorage(DefaultsKeys.prompterWidth) private var width = 620.0
    @AppStorage(DefaultsKeys.prompterOpacity) private var opacity = 0.92
    @AppStorage(DefaultsKeys.prompterHiddenFromCapture) private var hiddenFromCapture = true
    @ObservedObject private var prompter = Prompter.shared
    @State private var settingsSearch = ""
    @State private var draft = ""

    private var search: SettingsSearchMatcher { SettingsSearchMatcher(query: settingsSearch) }

    private var layout: SettingsPageLayout { SettingsPageLayout(sections: [.prompter, .prompterLook]) }

    private func shows(_ section: SettingsSection) -> Bool { layout.shows(section, for: search) }

    var body: some View {
        SettingsForm(query: $settingsSearch, hasMatches: layout.hasMatches(for: search)) {
            if shows(.prompter) { scriptSection }
            if shows(.prompterLook) { lookSection }
        }
        .onAppear { draft = prompter.text }
        .onChange(of: prompter.text) { _, text in if text != draft { draft = text } }
        .onChange(of: draft) { _, text in prompter.setText(text) }
    }

    private var scriptSection: some View {
        Section {
            TextEditor(text: $draft)
                .font(.app(size: 13))
                .frame(minHeight: 180)
                .scrollContentBackground(.hidden)
            HStack {
                Button(prompter.isShown ? "Close Prompter" : "Show Prompter") { prompter.toggle() }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.Accent.primary)
                    .disabled(!prompter.hasScript && !prompter.isShown)
                Button("Load from Clipboard") { prompter.loadFromClipboard() }
                Spacer()
                Text("\(prompter.script.spokenWords.count) words")
                    .font(.appMono(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let problem = prompter.problem {
                Label {
                    Text(verbatim: problem.message)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.app(.caption))
                .foregroundStyle(.orange)
            }
        } header: {
            Text("Voice Prompter")
        } footer: {
            Text(
                "The script scrolls under the notch as you read it aloud and waits when you stop. Words in [square brackets] are notes: they show but are never waited for. Click a word to start from it, or scroll over the prompter to move. Speech is recognized on this Mac."
            )
            .settingsCaption()
        }
    }

    private var lookSection: some View {
        Section {
            HStack(spacing: 10) {
                Text("Text Size")
                Slider(value: $fontSize, in: 14...48, step: 1)
                Text(verbatim: "\(Int(fontSize))").font(.appMono(size: 11)).foregroundStyle(.secondary)
                    .frame(width: 24, alignment: .trailing)
            }
            Stepper(value: $lines, in: 2...8) {
                Text("Lines Shown: \(lines)")
            }
            HStack(spacing: 10) {
                Text("Width")
                Slider(value: $width, in: 360...1000, step: 10)
            }
            HStack(spacing: 10) {
                Text("Background")
                Slider(value: $opacity, in: 0.4...1)
            }
            Toggle("Hide from Screenshots & Sharing", isOn: $hiddenFromCapture)
        } header: {
            Text("Prompter Look")
        } footer: {
            Text(
                "Hidden, the prompter stays out of screenshots, recordings and screen sharing in apps like Zoom, Teams and Meet, so only you see the script."
            )
            .settingsCaption()
        }
    }
}
