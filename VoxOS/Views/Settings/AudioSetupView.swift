import CoreAudio
import SwiftUI

struct AudioSetupView: View {
    @ObservedObject private var audioDeviceManager = AudioDeviceManager.shared
    @ObservedObject private var mediaController = MediaController.shared
    @ObservedObject private var playbackController = PlaybackController.shared
    /// The single-microphone choice to return to when Priority Order is switched off. Persisted,
    /// because while Priority Order is on `onAppear` never captures a source, so a view rebuild
    /// would otherwise forget it. See `AudioDeviceManager.singleMicrophoneSourceKey`.
    @AppStorage(AudioDeviceManager.singleMicrophoneSourceKey) private var storedSingleMicrophoneSource = ""
    @State private var refreshIconRotation = 0.0

    private var microphoneSourceBeforePriorityOrder: MicrophoneSourceSelection {
        get {
            if let recorded = MicrophoneSourceSelection(storedValue: storedSingleMicrophoneSource) {
                return recorded
            }
            // Nothing recorded yet (an install from before this key): the last custom device is
            // the best guess, as it was before.
            return UserDefaults.standard.selectedAudioDeviceUID.map { .device($0) } ?? .systemDefault
        }
        nonmutating set {
            storedSingleMicrophoneSource = newValue.storedValue
        }
    }

    /// Below this content width the two columns stack.
    private static let twoColumnMinWidth: CGFloat = 640
    @State private var contentWidth: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                AppScreenHeader(title: "Audio")

                Group {
                    if contentWidth >= Self.twoColumnMinWidth {
                        HStack(alignment: .top, spacing: 16) {
                            inputColumn
                                .frame(maxWidth: .infinity)
                            recordingColumn
                                .frame(maxWidth: .infinity)
                        }
                    } else {
                        VStack(spacing: 20) {
                            inputColumn
                            recordingColumn
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    contentWidth = width
                }
            }
        }
        .labeledContentStyle(AudioSettingsRowStyle())
        .onAppear {
            if !usesPriorityOrder {
                microphoneSourceBeforePriorityOrder = currentMicrophoneSource
            }
        }
    }

    private var inputColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            AudioSettingsCard(title: "Audio input") {
                inputSettingsRows
            }

            if usesPriorityOrder {
                AudioSettingsCard(title: "Priority order") {
                    priorityOrderRows
                }
            }
        }
    }

    private var recordingColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            AudioSettingsCard(title: "Recording sounds") {
                CustomSoundSettingsView()
            }

            AudioSettingsCard(title: "Recording behavior") {
                LabeledContent("Mute audio while recording") {
                    Toggle("Mute audio while recording", isOn: $mediaController.isSystemMuteEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }

                Divider()

                LabeledContent("Pause media while recording") {
                    Toggle("Pause media while recording", isOn: $playbackController.isPauseMediaEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }

                Divider()

                LabeledContent("Resume delay") {
                    resumeDelayMenu
                        .disabled(!canEditResumeDelay)
                }
                .foregroundStyle(canEditResumeDelay ? AppTheme.Text.primary : AppTheme.Text.secondary)
            }
        }
    }

    @ViewBuilder
    private var inputSettingsRows: some View {
        LabeledContent("Microphone mode") {
            Picker("Microphone mode", selection: inputRouteSelection) {
                Text("Selected microphone").tag(InputRoute.singleMicrophone)
                Text("Priority order").tag(InputRoute.priorityOrder)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }

        if !usesPriorityOrder {
            Divider()

            LabeledContent("Microphone") {
                Picker("Microphone", selection: microphoneSourceSelection) {
                    Text(systemDefaultSourceTitle).tag(MicrophoneSourceSelection.systemDefault)

                    ForEach(audioDeviceManager.availableDevices, id: \.uid) { device in
                        Text(device.name).tag(MicrophoneSourceSelection.device(device.uid))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 220)
            }
        }

        Divider()

        LabeledContent {
            Button {
                refreshMicrophones()
            } label: {
                Label {
                    Text("Refresh")
                } icon: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(refreshIconRotation))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Refresh Microphones")
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Microphones")
                Text(String(format: String(localized: "%lld found"), Int64(audioDeviceManager.availableDevices.count)))
                    .font(.appMono(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.Text.muted)
            }
        }
    }

    @ViewBuilder
    private var priorityOrderRows: some View {
        if prioritizedDevicesInDisplayOrder.isEmpty {
            Text("Add microphones in the order VoxOS should try them.")
                .font(.app(size: 13))
                .foregroundStyle(AppTheme.Text.secondary)
                .padding(.vertical, 8)
        } else {
            ForEach(prioritizedDevicesInDisplayOrder) { device in
                if device.id != prioritizedDevicesInDisplayOrder.first?.id {
                    Divider()
                }
                priorityDeviceRow(for: device)
                    .padding(.vertical, 8)
            }
        }

        if !availableDevicesNotInPriorityOrder.isEmpty {
            ForEach(availableDevicesNotInPriorityOrder, id: \.uid) { device in
                Divider()
                availablePriorityDeviceRow(for: device)
                    .padding(.vertical, 8)
            }
        }
    }

    private var inputRouteSelection: Binding<InputRoute> {
        Binding(
            get: { usesPriorityOrder ? .priorityOrder : .singleMicrophone },
            set: { route in
                switch route {
                case .singleMicrophone:
                    selectSingleMicrophoneMode()
                case .priorityOrder:
                    selectPriorityOrderMode()
                }
            }
        )
    }

    private var microphoneSourceSelection: Binding<MicrophoneSourceSelection> {
        Binding(
            get: { currentMicrophoneSource },
            set: { selection in
                microphoneSourceBeforePriorityOrder = selection
                selectMicrophoneSource(selection)
            }
        )
    }

    private func availablePriorityDeviceRow(for device: (id: AudioDeviceID, uid: String, name: String)) -> some View {
        Button {
            audioDeviceManager.addPrioritizedDevice(uid: device.uid, name: device.name)
        } label: {
            HStack(spacing: 8) {
                Label(device.name, systemImage: "plus.circle")
                    .lineLimit(1)

                Spacer()

                Text("Add")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func priorityDeviceRow(for prioritizedDevice: PrioritizedDevice) -> some View {
        let device = audioDeviceManager.availableDevices.first { $0.uid == prioritizedDevice.id }
        let isAvailable = device != nil
        let isActive = device.map { audioDeviceManager.getCurrentDevice() == $0.id } ?? false

        return HStack(spacing: 8) {
            Text("\(prioritizedDevice.priority + 1)")
                .font(.appMono(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(prioritizedDevice.name)
                    .foregroundStyle(isAvailable ? .primary : .secondary)
                    .lineLimit(1)

                if !isAvailable {
                    Text("Unavailable")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isActive {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
            }

            HStack(spacing: 4) {
                Button {
                    movePrioritizedDeviceUp(prioritizedDevice)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .disabled(prioritizedDevice.id == prioritizedDevicesInDisplayOrder.first?.id)
                .help("Move up")

                Button {
                    movePrioritizedDeviceDown(prioritizedDevice)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .disabled(prioritizedDevice.id == prioritizedDevicesInDisplayOrder.last?.id)
                .help("Move down")

                Button {
                    audioDeviceManager.removePrioritizedDevice(id: prioritizedDevice.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .help("Remove")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    private var currentMicrophoneSource: MicrophoneSourceSelection {
        switch audioDeviceManager.inputMode {
        case .systemDefault:
            return .systemDefault
        case .custom:
            if let selectedDeviceUID {
                return .device(selectedDeviceUID)
            }
            return .systemDefault
        case .prioritized:
            return microphoneSourceBeforePriorityOrder
        }
    }

    private func selectMicrophoneSource(_ selection: MicrophoneSourceSelection) {
        switch selection {
        case .systemDefault:
            audioDeviceManager.selectInputMode(.systemDefault)
        case .device(let uid):
            guard let device = audioDeviceManager.availableDevices.first(where: { $0.uid == uid }) else {
                audioDeviceManager.selectInputMode(.systemDefault)
                return
            }
            audioDeviceManager.selectDeviceAndSwitchToCustomMode(id: device.id)
        }
    }

    private func selectSingleMicrophoneMode() {
        selectMicrophoneSource(microphoneSourceBeforePriorityOrder)
    }

    private func selectPriorityOrderMode() {
        if !usesPriorityOrder {
            microphoneSourceBeforePriorityOrder = currentMicrophoneSource
        }
        audioDeviceManager.selectInputMode(.prioritized)
    }

    private var selectedDeviceUID: String? {
        guard let selectedDeviceID = audioDeviceManager.selectedDeviceID else { return nil }
        return audioDeviceManager.availableDevices.first { $0.id == selectedDeviceID }?.uid
    }

    private var systemDefaultSourceTitle: String {
        guard let name = audioDeviceManager.getSystemDefaultDeviceName() else {
            return String(localized: "System Default")
        }
        return String(format: String(localized: "System Default (%@)"), name)
    }

    private func refreshMicrophones() {
        withAnimation(.easeInOut(duration: 0.35)) {
            refreshIconRotation += 360
        }
        audioDeviceManager.loadAvailableDevices()
    }

    private var usesPriorityOrder: Bool {
        audioDeviceManager.inputMode == .prioritized
    }

    private var prioritizedDevicesInDisplayOrder: [PrioritizedDevice] {
        audioDeviceManager.prioritizedDevices.sorted { $0.priority < $1.priority }
    }

    private var availableDevicesNotInPriorityOrder: [(id: AudioDeviceID, uid: String, name: String)] {
        audioDeviceManager.availableDevices.filter { device in
            !audioDeviceManager.prioritizedDevices.contains { $0.id == device.uid }
        }
    }

    private var resumeDelayMenu: some View {
        Picker("Resume Delay", selection: $mediaController.audioResumptionDelay) {
            Text("0s").tag(0.0)
            Text("1s").tag(1.0)
            Text("2s").tag(2.0)
            Text("3s").tag(3.0)
            Text("4s").tag(4.0)
            Text("5s").tag(5.0)
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }

    private var canEditResumeDelay: Bool {
        mediaController.isSystemMuteEnabled || playbackController.isPauseMediaEnabled
    }

    private func movePrioritizedDeviceUp(_ device: PrioritizedDevice) {
        var devices = prioritizedDevicesInDisplayOrder
        guard let currentIndex = devices.firstIndex(where: { $0.id == device.id }),
            currentIndex > 0
        else { return }

        devices.swapAt(currentIndex, currentIndex - 1)
        updatePriorities(devices)
    }

    private func movePrioritizedDeviceDown(_ device: PrioritizedDevice) {
        var devices = prioritizedDevicesInDisplayOrder
        guard let currentIndex = devices.firstIndex(where: { $0.id == device.id }),
            currentIndex < devices.count - 1
        else { return }

        devices.swapAt(currentIndex, currentIndex + 1)
        updatePriorities(devices)
    }

    private func updatePriorities(_ devices: [PrioritizedDevice]) {
        let updatedDevices = devices.enumerated().map { index, device in
            PrioritizedDevice(id: device.id, name: device.name, priority: index, modelUID: device.modelUID)
        }
        audioDeviceManager.updatePriorities(devices: updatedDevices)
    }
}

private enum MicrophoneSourceSelection: Hashable {
    case systemDefault
    case device(String)

    private static let systemDefaultValue = "systemDefault"
    private static let devicePrefix = "device:"

    /// nil for an empty or unrecognised value, which means no choice has been recorded.
    init?(storedValue: String) {
        if storedValue == Self.systemDefaultValue {
            self = .systemDefault
        } else if storedValue.hasPrefix(Self.devicePrefix) {
            let uid = String(storedValue.dropFirst(Self.devicePrefix.count))
            guard !uid.isEmpty else { return nil }
            self = .device(uid)
        } else {
            return nil
        }
    }

    var storedValue: String {
        switch self {
        case .systemDefault:
            return Self.systemDefaultValue
        case .device(let uid):
            return Self.devicePrefix + uid
        }
    }
}

private enum InputRoute: Hashable {
    case singleMicrophone
    case priorityOrder
}

// MARK: - Cards

/// A grouped card from the design spec: a mono eyebrow over a 14pt-radius card whose rows are
/// separated by dividers the caller places.
private struct AudioSettingsCard<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    private static var radius: CGFloat { 14 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.appMono(size: 11, weight: .medium))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(AppTheme.Text.secondary)
                .padding(.leading, 4)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .font(.app(size: 13))
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .fill(AppTheme.Surface.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                    .strokeBorder(AppTheme.Border.card, lineWidth: 1)
            )
        }
    }
}

/// Label on the left, control on the right, one row of a settings card.
private struct AudioSettingsRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
                .lineLimit(2)
            Spacer(minLength: 12)
            configuration.content
        }
        .frame(minHeight: 28)
        .padding(.vertical, 8)
    }
}
