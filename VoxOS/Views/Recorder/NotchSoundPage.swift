import AppKit
import CoreAudio
import SwiftUI
import UniformTypeIdentifiers

/// One page for the extras, so they do not each take a page: each app's volume, the sound output,
/// the microphone and the camera mirror (each when switched on in Settings), with keeping the Mac
/// awake and pinning the card in its corner.
struct NotchSoundPage: View {
    enum Section: String, CaseIterable, Identifiable {
        case apps
        case output
        case input
        case mirror

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .apps: return "square.grid.2x2"
            case .output: return "speaker.wave.2"
            case .input: return "mic"
            case .mirror: return "person.crop.square"
            }
        }

        var label: LocalizedStringKey {
            switch self {
            case .apps: return "App volumes"
            case .output: return "Sound output"
            case .input: return "Microphone"
            case .mirror: return "Mirror"
            }
        }
    }

    /// Tall enough for three app rows, and for the camera to be seen.
    static var cardHeight: CGFloat { NotchWeatherPage.cardHeight }

    @ObservedObject var mixer: NotchMixer
    @ObservedObject var mirror: NotchMirror
    @ObservedObject var keepAwake: NotchKeepAwake
    @ObservedObject private var audioDeviceManager = AudioDeviceManager.shared
    let pinned: Bool
    let onPin: () -> Void
    /// Whether the mirror is the part shown, for the card's height.
    var onMirrorShown: (Bool) -> Void = { _ in }
    @AppStorage(DefaultsKeys.notchMixerEnabled) private var appsOn = true
    @AppStorage(DefaultsKeys.notchSoundOutputEnabled) private var outputOn = true
    @AppStorage(DefaultsKeys.notchSoundInputEnabled) private var inputOn = true
    @AppStorage(DefaultsKeys.notchMirrorEnabled) private var mirrorOn = true
    @AppStorage(DefaultsKeys.notchSoundSection) private var selectedSectionRaw = Section.apps.rawValue

    private var sections: [Section] {
        Section.allCases.filter { section in
            switch section {
            case .apps: return appsOn
            case .output: return outputOn
            case .input: return inputOn
            case .mirror: return mirrorOn
            }
        }
    }

    private var shown: Section? {
        if let current = Section(rawValue: selectedSectionRaw), sections.contains(current) {
            return current
        }
        return sections.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(sections) { item in
                    NotchSegmentButton(symbol: item.symbol, label: item.label, selected: item == shown) {
                        selectedSectionRaw = item.rawValue
                    }
                }
                Spacer(minLength: 6)
                NotchToggleChip(
                    symbol: keepAwake.isOn ? "cup.and.saucer.fill" : "cup.and.saucer", on: keepAwake.isOn,
                    tint: .orange,
                    help: keepAwake.isOn ? "Keeping the Mac awake. Click to let it sleep." : "Keep the Mac awake"
                ) { keepAwake.toggle() }
                NotchToggleChip(
                    symbol: pinned ? "pin.fill" : "pin", on: pinned, tint: AppTheme.Accent.primary,
                    help: pinned ? "Unpin: close when the pointer leaves" : "Pin: keep the card open", action: onPin)
            }
            .frame(height: 22)

            Group {
                switch shown {
                case .apps: apps
                case .output: outputList
                case .input: inputList
                case .mirror: mirrorView
                case nil:
                    Text("Switch on sound features in Settings → Notch Home")
                        .font(.app(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.top, 2)
        .padding(.horizontal, AgentComposer.panelInset)
        .padding(.bottom, NotchHome.Card.bottom)
        .onAppear {
            mixer.setVisible(shown == .apps)
            onMirrorShown(shown == .mirror)
        }
        .onChange(of: shown) { old, new in
            mixer.setVisible(new == .apps)
            if old == .mirror { mirror.stop() }
            onMirrorShown(new == .mirror)
        }
        // Leaving the page, or the card closing, stops the camera and the app list's listening.
        .onDisappear {
            mixer.setVisible(false)
            mirror.stop()
            onMirrorShown(false)
        }
    }

    // MARK: Apps

    @ViewBuilder
    private var apps: some View {
        if mixer.apps.isEmpty {
            NotchPageHint(symbol: "square.grid.2x2", text: "Apps that can play sound show here")
        } else {
            ScrollView(.vertical) {
                VStack(spacing: 6) {
                    ForEach(mixer.apps) { app in
                        NotchAppVolumeRow(app: app) { mixer.setGain($0, for: app.bundleID) }
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
    }

    // MARK: Output

    @ViewBuilder
    private var outputList: some View {
        NotchSoundOutputList()
    }

    // MARK: Microphone Input

    @ViewBuilder
    private var inputList: some View {
        NotchSoundInputList(audioDeviceManager: audioDeviceManager)
    }

    // MARK: Mirror

    @ViewBuilder
    private var mirrorView: some View {
        switch mirror.state {
        case .on:
            NotchMirrorPreview(layer: mirror.previewLayer)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        case .starting:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .off:
            VStack(spacing: 6) {
                Text("A mirror, before a call. The camera stays off until you ask.")
                    .font(.app(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                NotchChip(title: String(localized: "Show the camera"), prominent: true) { mirror.start() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .denied:
            VStack(spacing: 6) {
                Text("Camera access is off").font(.app(size: 11)).foregroundStyle(.white.opacity(0.5))
                NotchChip(title: String(localized: "Open Settings")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noCamera:
            NotchPageHint(symbol: "video.slash", text: "No camera found")
        }
    }
}

/// An icon, and a line under it, for a part of a page with nothing in it yet.
struct NotchPageHint: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium))
            Text(text).font(.app(size: 11))
        }
        .foregroundStyle(.white.opacity(0.45))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A part of the Sound page, chosen by its icon.
private struct NotchSegmentButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(selected ? 1 : hovered ? 0.85 : 0.55))
                .frame(width: 30, height: 20)
                .background(Capsule().fill(.white.opacity(selected ? 0.18 : hovered ? 0.1 : 0.05)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(Text(label))
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Keep awake or pin: lit in its colour while on.
private struct NotchToggleChip: View {
    let symbol: String
    let on: Bool
    let tint: Color
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(on ? tint : .white.opacity(hovered ? 0.95 : 0.6))
                .frame(width: 24, height: 20)
                .background(Capsule().fill(.white.opacity(hovered || on ? 0.14 : 0.06)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// One app's volume as a wide capsule that fills from the left to its level: dragged or clicked
/// anywhere along it, the level follows the pointer.
private struct NotchAppVolumeRow: View {
    let app: NotchMixer.App
    let onChange: (Float) -> Void

    static let height: CGFloat = 40

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.07))
                Rectangle()
                    .fill(.white.opacity(0.24))
                    .frame(width: geometry.size.width * CGFloat(app.gain))
                HStack(spacing: 10) {
                    if let icon = NotchHomeApp.icon(for: app.bundleID) {
                        Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                    }
                    Text(verbatim: app.name)
                        .font(.app(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(verbatim: "\(Int((app.gain * 100).rounded()))%")
                        .font(.app(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 14)
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onChange(Float(NotchAppVolumeRow.level(at: value.location.x, width: geometry.size.width)))
                    }
            )
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(app.name) volume"))
        .accessibilityValue(Text("\(Int((app.gain * 100).rounded())) percent"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onChange(min(1, app.gain + 0.1))
            case .decrement: onChange(max(0, app.gain - 0.1))
            @unknown default: break
            }
        }
    }

    /// The level for a pointer at `x` along a row `width` wide, in whole percent.
    nonisolated static func level(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 1 }
        return (min(max(Double(x / width), 0), 1) * 100).rounded() / 100
    }
}

/// Lists every available audio output device and ticks the current default output;
/// clicking one switches the Mac's sound output to that device.
private struct NotchSoundOutputList: View {
    @State private var devices: [NotchAudioOutput.Device] = []
    @State private var current = AudioObjectID(kAudioObjectUnknown)

    var body: some View {
        Group {
            if devices.isEmpty {
                NotchPageHint(symbol: "speaker.slash", text: "No output devices found")
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 4) {
                        ForEach(devices, id: \.id) { device in
                            row(device)
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AudioDeviceChanged"))) { _ in
            reload()
        }
    }

    private func row(_ device: NotchAudioOutput.Device) -> some View {
        let selected = device.id == current
        return NotchAudioDeviceRow(
            symbol: NotchAudioOutput.pickerSymbol(for: device),
            name: device.name,
            selected: selected
        ) {
            current = device.id
            NotchHome.tap()
            Task.detached(priority: .userInitiated) {
                NotchAudioOutput.makeDefaultOutput(device.id)
                await MainActor.run { reload() }
            }
        }
    }

    private func reload() {
        devices = NotchAudioOutput.outputDevices()
        current = NotchAudioOutput.defaultOutput()
    }
}

/// Lists every available microphone device and ticks the active microphone;
/// clicking one switches VoxOS's active recording device and the Mac's default input.
private struct NotchSoundInputList: View {
    @ObservedObject var audioDeviceManager: AudioDeviceManager
    @State private var selectedID: AudioDeviceID?

    var body: some View {
        let devices = audioDeviceManager.availableDevices
        Group {
            if devices.isEmpty {
                NotchPageHint(symbol: "mic.slash", text: "No microphones found")
            } else {
                let currentActiveID = selectedID ?? audioDeviceManager.getCurrentDevice()
                ScrollView(.vertical) {
                    VStack(spacing: 4) {
                        ForEach(devices, id: \.id) { device in
                            let selected = device.id == currentActiveID
                            NotchAudioDeviceRow(
                                symbol: audioDeviceManager.symbol(for: device.id, name: device.name),
                                name: device.name,
                                selected: selected
                            ) {
                                selectedID = device.id
                                NotchHome.tap()
                                audioDeviceManager.selectDeviceAndSwitchToCustomMode(id: device.id)
                                audioDeviceManager.makeDefaultInput(id: device.id)
                            }
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
        }
        .onAppear {
            selectedID = audioDeviceManager.getCurrentDevice()
            audioDeviceManager.loadAvailableDevices()
        }
        .onChange(of: audioDeviceManager.selectedDeviceID) { newID in
            if let newID { selectedID = newID }
        }
    }
}

/// A row for an audio output or input device with icon, name, and checkmark if selected.
private struct NotchAudioDeviceRow: View {
    let symbol: String
    let name: String
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? AppTheme.Accent.primary : .white.opacity(hovered ? 0.95 : 0.7))
                    .frame(width: 18)
                Text(verbatim: name)
                    .font(.app(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(selected ? 1 : hovered ? 0.95 : 0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(AppTheme.Accent.primary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(selected ? 0.12 : hovered ? 0.08 : 0.03))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(name)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(name))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
