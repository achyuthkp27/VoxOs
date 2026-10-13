import SwiftUI
import UniformTypeIdentifiers

struct CustomSoundSettingsView: View {
    @StateObject private var customSoundManager = CustomSoundManager.shared
    /// Which row's file failed. The alert is attached per row, so a shared Bool on the `Group`
    /// would present it once from each row; keying it by sound type presents it exactly once.
    @State private var alertSoundType: CustomSoundManager.SoundType?
    @State private var alertTitle = ""
    @State private var alertMessage = ""

    private enum SoundMenuSelection: Hashable {
        case none
        case builtIn(CustomSoundManager.BuiltInSound)
        case custom
    }

    var body: some View {
        Group {
            LabeledContent("Start Sound") {
                soundControls(for: .start)
            }
            .alert(alertTitle, isPresented: alertPresented(for: .start)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }

            LabeledContent("Stop Sound") {
                soundControls(for: .stop)
            }
            .alert(alertTitle, isPresented: alertPresented(for: .stop)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
        }
    }

    private func alertPresented(for type: CustomSoundManager.SoundType) -> Binding<Bool> {
        Binding(
            get: { alertSoundType == type },
            set: { isPresented in
                if !isPresented, alertSoundType == type {
                    alertSoundType = nil
                }
            }
        )
    }

    @ViewBuilder
    private func soundControls(for type: CustomSoundManager.SoundType) -> some View {
        let selection = customSoundManager.soundSelection(for: type)
        let isCustom = selection.isCustom
        let fileName = customSoundManager.getSoundDisplayName(for: type)
        let isEnabled = selection.isEnabled

        HStack(spacing: 8) {
            Picker("Sound", selection: soundSelectionBinding(for: type)) {
                Text("None").tag(SoundMenuSelection.none)

                ForEach(CustomSoundManager.BuiltInSound.allCases) { sound in
                    Text(sound.displayName).tag(SoundMenuSelection.builtIn(sound))
                }

                if isCustom || fileName != nil {
                    Text(String(format: String(localized: "Custom: %@"), fileName ?? String(localized: "Custom"))).tag(
                        SoundMenuSelection.custom)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 116, alignment: .trailing)
            .fixedSize()
            .help("Select sound")

            Button {
                if type == .start {
                    SoundManager.shared.playStartSound()
                } else {
                    SoundManager.shared.playStopSound()
                }
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!isEnabled)
            .help("Test")

            Button {
                selectSound(for: type)
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("Choose")

            if !customSoundManager.isDefaultSelection(for: type) {
                Button {
                    if !isEnabled || isCustom {
                        customSoundManager.resetSoundToDefault(for: type)
                    } else {
                        customSoundManager.selectBuiltInSound(type.defaultBuiltInSound, for: type)
                    }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Reset")
            }
        }
    }

    private func soundSelectionBinding(for type: CustomSoundManager.SoundType) -> Binding<SoundMenuSelection> {
        Binding(
            get: {
                switch customSoundManager.soundSelection(for: type) {
                case .none:
                    return .none
                case .builtIn(let sound):
                    return .builtIn(sound)
                case .custom:
                    return .custom
                }
            },
            set: { selection in
                switch selection {
                case .none:
                    customSoundManager.selectNoSound(for: type)
                case .builtIn(let sound):
                    customSoundManager.selectBuiltInSound(sound, for: type)
                case .custom:
                    customSoundManager.useCustomSound(for: type)
                }
            }
        )
    }

    private func selectSound(for type: CustomSoundManager.SoundType) {
        let panel = NSOpenPanel()
        panel.title = String(format: String(localized: "Choose %@ Sound"), type.rawValue.capitalized)
        panel.message = String(localized: "Select an audio file")
        panel.allowedContentTypes = [
            UTType.audio,
            UTType.mp3,
            UTType.wav,
            UTType.aiff,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }

            let result = customSoundManager.setCustomSound(url: url, for: type)
            if case .failure(let error) = result {
                alertTitle = "Invalid Audio File"
                alertMessage = error.localizedDescription
                alertSoundType = type
            }
        }
    }
}

#Preview {
    CustomSoundSettingsView()
        .frame(width: 400)
        .padding()
}
