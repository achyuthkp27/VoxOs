import AppKit
import SwiftUI

/// The Voice Prompter page: the script and the button that shows the prompter, then how the
/// prompter looks.
struct PrompterSettingsPage: View {
    @AppStorage(DefaultsKeys.prompterFontSize) private var fontSize = 20.0
    @AppStorage(DefaultsKeys.prompterLines) private var lines = 4
    @AppStorage(DefaultsKeys.prompterWidth) private var width = 380.0
    @AppStorage(DefaultsKeys.prompterOpacity) private var opacity = 1.0
    @AppStorage(DefaultsKeys.prompterTextColor) private var textColorHex = ""
    @AppStorage(DefaultsKeys.prompterFollow) private var follow = PrompterFollow.words.rawValue
    @AppStorage(DefaultsKeys.prompterPace) private var pace = 140.0
    @AppStorage(DefaultsKeys.prompterPaceWhileSpeaking) private var paceWhileSpeaking = true
    @AppStorage(DefaultsKeys.prompterMicSensitivity) private var micSensitivity = 0.5
    @AppStorage(DefaultsKeys.prompterHiddenFromCapture) private var hiddenFromCapture = true
    @ObservedObject private var prompter = Prompter.shared
    @State private var settingsSearch = ""
    @State private var draft = ""

    private var search: SettingsSearchMatcher { SettingsSearchMatcher(query: settingsSearch) }

    private var layout: SettingsPageLayout {
        SettingsPageLayout(sections: [.prompter, .prompterFollow, .prompterLook])
    }

    private func shows(_ section: SettingsSection) -> Bool { layout.shows(section, for: search) }

    var body: some View {
        SettingsForm(query: $settingsSearch, hasMatches: layout.hasMatches(for: search)) {
            if shows(.prompter) { scriptSection }
            if shows(.prompterFollow) { followSection }
            if shows(.prompterLook) { lookSection }
        }
        .onAppear { draft = prompter.text }
        .onChange(of: prompter.text) { _, text in if text != draft { draft = text } }
        .onChange(of: draft) { _, text in prompter.setText(text) }
        .onChange(of: follow) { _, _ in prompter.followChanged() }
        .onChange(of: paceWhileSpeaking) { _, _ in prompter.followChanged() }
    }

    private var followSection: some View {
        Section {
            Picker("Follow", selection: $follow) {
                Text("Words Read Aloud").tag(PrompterFollow.words.rawValue)
                Text("Steady Pace").tag(PrompterFollow.pace.rawValue)
            }
            if follow == PrompterFollow.pace.rawValue {
                HStack(spacing: 10) {
                    Text("Pace")
                    Slider(value: $pace, in: 60...240, step: 5)
                    Text("\(Int(pace)) wpm").font(.appMono(size: 11)).foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                }
                Toggle("Only While Speaking", isOn: $paceWhileSpeaking)
                if paceWhileSpeaking {
                    HStack(spacing: 10) {
                        Text("Mic Sensitivity")
                        Slider(value: $micSensitivity, in: 0...1)
                    }
                }
            }
        } header: {
            Text("Follow")
        } footer: {
            Text(
                "Words Read Aloud follows what you say, word by word. Steady Pace scrolls at a set speed instead and works in any language; with Only While Speaking it waits whenever you go quiet. Either way it waits while the pointer is over the prompter."
            )
            .settingsCaption()
        }
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
                "The script scrolls under the notch as you read it aloud and waits when you stop. Words in [square brackets] are notes: they show but are never waited for. Click a word to start from it, scroll over the prompter to move, or drag its bottom-right corner to resize it. Speech is recognized on this Mac."
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
            Stepper(value: $lines, in: PrompterWindow.linesRange) {
                Text("Lines Shown: \(lines)")
            }
            HStack(spacing: 10) {
                Text("Width")
                Slider(
                    value: $width,
                    in: Double(PrompterWindow.widthRange.lowerBound)...Double(PrompterWindow.widthRange.upperBound),
                    step: 10)
            }
            HStack(spacing: 10) {
                Text("Background")
                Slider(value: $opacity, in: 0.4...1)
            }
            ColorPicker(
                "Text Color",
                selection: Binding(
                    get: { PrompterTextColor.color(hex: textColorHex) },
                    set: { textColorHex = PrompterTextColor.hex($0) }),
                supportsOpacity: false)
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
