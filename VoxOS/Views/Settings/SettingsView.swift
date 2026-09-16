import Carbon.HIToolbox
import Cocoa
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var updaterViewModel: UpdaterViewModel
    @EnvironmentObject private var menuBarManager: MenuBarManager
    @EnvironmentObject private var recordingShortcutManager: RecordingShortcutManager
    @EnvironmentObject private var recorderUIManager: RecorderUIManager
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @ObservedObject private var launchAtLoginManager = LaunchAtLoginManager.shared
    @ObservedObject private var mediaController = MediaController.shared
    @ObservedObject private var playbackController = PlaybackController.shared
    @AppStorage("hasCompletedOnboardingV2") private var hasCompletedOnboardingV2 = true
    @AppStorage("enableAnnouncements") private var enableAnnouncements = true
    @AppStorage("restoreClipboardAfterPaste") private var restoreClipboardAfterPaste = true
    @AppStorage("clipboardRestoreDelay") private var clipboardRestoreDelay = 2.0
    @AppStorage(PasteMethod.userDefaultsKey) private var pasteMethodRawValue = PasteMethod.standard.rawValue
    @AppStorage(AppAppearancePreference.userDefaultsKey) private var appAppearancePreference = AppAppearancePreference
        .system
    @AppStorage(AppLanguagePreference.userDefaultsKey) private var appLanguagePreference = AppLanguagePreference
        .systemValue
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true
    @State private var showResetOnboardingAlert = false
    @State private var showLanguageRestartAlert = false
    @State private var cancelRecordingShortcutRecorderResetID = 0

    @ObservedObject private var systemAudioController = SystemAudioCaptureController.shared
    @AppStorage(SystemAudioCaptureController.DefaultsKey.bufferEnabled) private var systemAudioBufferEnabled = false
    @AppStorage(SystemAudioCaptureController.DefaultsKey.bufferSeconds) private var systemAudioBufferSeconds =
        SystemAudioCaptureController.defaultBufferSeconds
    @AppStorage(SystemAudioCaptureController.DefaultsKey.pasteAtCursor) private var systemAudioPasteAtCursor = true
    @AppStorage(SystemAudioCaptureController.DefaultsKey.saveToHistory) private var systemAudioSaveToHistory = true

    @State private var isMiddleClickExpanded = false
    @State private var isSystemAudioBufferExpanded = false
    @State private var agentHasAccessibility = AXIsProcessTrusted()
    @State private var agentHasScreenRecording = CGPreflightScreenCaptureAccess()
    @AppStorage(AgentControlMode.userDefaultsKey) private var agentControlModeRaw = AgentControlMode.takeover.rawValue
    @AppStorage(AgentShell.allowRiskyKey) private var agentAllowRiskyShell = false
    @AppStorage(AgentAutoSend.enabledKey) private var agentAutoSendEnabled = true
    @AppStorage(DictationSend.stopWhenQuietKey) private var dictationStopWhenQuiet = false
    @AppStorage(DictationSend.pressReturnKey) private var dictationPressReturn = false
    @AppStorage(AgentAutoSend.pauseKey) private var agentAutoSendPause = AgentAutoSend.Pause.normal.rawValue
    @State private var isRestoreClipboardExpanded = false
    @AppStorage(WritingDestination.isEnabledKey) private var matchWritingStyleToApp = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Primary Shortcut") {
                    HStack(spacing: 8) {
                        Spacer()
                        shortcutModePicker(binding: $recordingShortcutManager.primaryRecordingShortcutMode)
                        ShortcutRecorder(action: .primaryRecording) {
                            recordingShortcutManager.primaryRecordingShortcut = .custom
                            recordingShortcutManager.updateShortcutStatus()
                        }
                        .controlSize(.small)
                    }
                }

                if recordingShortcutManager.secondaryRecordingShortcut != .none {
                    LabeledContent("Secondary Shortcut") {
                        HStack(spacing: 8) {
                            Spacer()
                            shortcutModePicker(binding: $recordingShortcutManager.secondaryRecordingShortcutMode)
                            ShortcutRecorder(action: .secondaryRecording) {
                                recordingShortcutManager.secondaryRecordingShortcut = .custom
                                recordingShortcutManager.updateShortcutStatus()
                            }
                            .controlSize(.small)
                            Button {
                                withAnimation { recordingShortcutManager.secondaryRecordingShortcut = .none }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if recordingShortcutManager.secondaryRecordingShortcut == .none {
                    Button("Add Second Shortcut") {
                        withAnimation { recordingShortcutManager.secondaryRecordingShortcut = .custom }
                    }
                }

                if recordingShortcutManager.isPrimaryShortcutFnKey {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(
                            "Hold fn to talk, tap fn to record hands-free, hold fn+⌃ to dictate and press Return. Double-tap ⌃ for the Agent — it sends when you stop talking."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        if !RecordingShortcutManager.systemFnKeyActionIsOff {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(
                                    "macOS also reacts to a bare fn tap. Set “Press 🌐 key to” to “Do Nothing” in System Settings → Keyboard."
                                )
                                .font(.callout)
                                Spacer()
                                Button("Open Keyboard Settings") {
                                    if let url = URL(
                                        string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
                                    {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }

                Toggle(isOn: $dictationStopWhenQuiet) {
                    HStack(spacing: 2) {
                        Text("Stop Dictation When You Stop Talking")
                        InfoTip(
                            "For dictation started with a tap: VoxOS stops and pastes once you pause, a little longer than the Agent's pause."
                        )
                    }
                }
                Toggle(isOn: $dictationPressReturn) {
                    HStack(spacing: 2) {
                        Text("Press Return After Pasting")
                        InfoTip(
                            "Sends what you dictated in chat boxes. Without this, hold fn+⌃ to dictate and send just once. A mode's own auto-send key still wins."
                        )
                    }
                }

                if !recordingShortcutManager.isPrimaryShortcutFnKey {
                    Button("Use the fn key (hold to talk, double-tap for Agent)") {
                        recordingShortcutManager.useFnKeyPreset()
                    }
                }
            } header: {
                Text("Shortcuts")
            }

            Section("Additional Shortcuts") {
                LabeledContent("Paste Last Transcription (Original)") {
                    ShortcutRecorder(action: .pasteLastTranscription) {
                        recordingShortcutManager.updateShortcutStatus()
                    }
                    .controlSize(.small)
                }

                LabeledContent("Paste Last Transcription (Enhanced)") {
                    ShortcutRecorder(action: .pasteLastEnhancement) {
                        recordingShortcutManager.updateShortcutStatus()
                    }
                    .controlSize(.small)
                }

                LabeledContent("Retry Last Transcription") {
                    ShortcutRecorder(action: .retryLastTranscription) {
                        recordingShortcutManager.updateShortcutStatus()
                    }
                    .controlSize(.small)
                }

                LabeledContent {
                    HStack(spacing: 8) {
                        ShortcutRecorder(
                            action: .cancelRecorder,
                            defaultShortcut: Self.defaultCancelRecordingShortcut
                        )
                        .id(cancelRecordingShortcutRecorderResetID)
                        .controlSize(.small)

                        Button {
                            RecorderPanelShortcutManager.resetEscapeConfirmationHint()
                            ShortcutStore.setShortcut(nil, for: .cancelRecorder)
                            cancelRecordingShortcutRecorderResetID += 1
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.plain)
                        .help("Reset to default")
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text("Cancel Recording")
                        InfoTip(
                            "The assigned shortcut cancels the recording. Resetting restores the default double-Escape behavior."
                        )
                    }
                }

                ExpandableSettingsRow(
                    isExpanded: $isMiddleClickExpanded,
                    isEnabled: $recordingShortcutManager.isMiddleClickToggleEnabled,
                    label: "Middle-Click Recording"
                ) {
                    LabeledContent("Activation Delay") {
                        HStack {
                            TextField(
                                "", value: $recordingShortcutManager.middleClickActivationDelay,
                                formatter: {
                                    let formatter = NumberFormatter()
                                    formatter.minimum = 0
                                    return formatter
                                }()
                            )
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                            Text("ms")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section {
                LabeledContent {
                    ShortcutRecorder(action: .captureSystemAudio) {
                        recordingShortcutManager.updateShortcutStatus()
                    }
                    .controlSize(.small)
                } label: {
                    HStack(spacing: 2) {
                        Text("Capture System Audio")
                        InfoTip(
                            "Press once to start capturing what your Mac is playing, press again to stop. The transcript is copied to the clipboard and pasted at the cursor. Your microphone is never recorded."
                        )
                    }
                }

                ExpandableSettingsRow(
                    isExpanded: $isSystemAudioBufferExpanded,
                    isEnabled: $systemAudioBufferEnabled,
                    label: "Keep Recent System Audio",
                    infoMessage:
                        "Continuously keeps the last few seconds of system audio in memory (never on disk) so a shortcut can transcribe what was just said. Nothing is captured while this is off."
                ) {
                    Picker("Remember", selection: $systemAudioBufferSeconds) {
                        Text("15 seconds").tag(15.0)
                        Text("30 seconds").tag(30.0)
                        Text("60 seconds").tag(60.0)
                        Text("2 minutes").tag(120.0)
                    }
                    .pickerStyle(.menu)

                    LabeledContent("Transcribe Recent Audio") {
                        ShortcutRecorder(action: .recallSystemAudio) {
                            recordingShortcutManager.updateShortcutStatus()
                        }
                        .controlSize(.small)
                    }
                }

                Toggle("Paste at Cursor", isOn: $systemAudioPasteAtCursor)
                Toggle("Save to History", isOn: $systemAudioSaveToHistory)
            } header: {
                Text("System Audio")
            } footer: {
                Text(
                    systemAudioController.isCapturing
                        ? "Capturing system audio…"
                        : "Requires Screen Recording permission. Captures only what your Mac plays — never your microphone."
                )
                .font(.app(.caption))
                .foregroundStyle(.secondary)
            }
            .onChange(of: systemAudioBufferEnabled) { _, _ in
                Task { await systemAudioController.syncBufferingWithPreference() }
            }
            .onChange(of: systemAudioBufferSeconds) { _, _ in
                Task { await systemAudioController.syncBufferingWithPreference() }
            }

            Section {
                Picker("Control Mode", selection: $agentControlModeRaw) {
                    ForEach(AgentControlMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)

                Text((AgentControlMode(rawValue: agentControlModeRaw) ?? .takeover).summary)
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)

                Toggle(isOn: $agentAutoSendEnabled) {
                    HStack(spacing: 2) {
                        Text("Send When You Stop Talking")
                        InfoTip(
                            "After ⌃⌃, the Agent sends your request once you pause, so there is no second tap. It learns how quiet your room is each time, and in a noisy room it waits for the live transcript to settle instead."
                        )
                    }
                }

                if agentAutoSendEnabled {
                    Picker("Pause Before Sending", selection: $agentAutoSendPause) {
                        ForEach(AgentAutoSend.Pause.allCases) { pause in
                            Text("\(pause.label) (\(String(format: "%.1f", pause.rawValue))s)").tag(pause.rawValue)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Toggle(isOn: $agentAllowRiskyShell) {
                    HStack(spacing: 2) {
                        Text("Allow Risky Shell Commands")
                        InfoTip(
                            "Commands that look destructive (rm -rf, sudo, disk formatting, piping downloads into a shell…) are refused unless this is on. When on, they run and the agent tells you what it did."
                        )
                    }
                }

                LabeledContent("Plugins") {
                    Button("Open Plugins Folder") {
                        NSWorkspace.shared.open(AgentPlugins.directory)
                    }
                    .controlSize(.small)
                }

                LabeledContent("Permissions") {
                    HStack(spacing: 6) {
                        Label(
                            agentHasAccessibility ? "Accessibility" : "Accessibility missing",
                            systemImage: agentHasAccessibility ? "checkmark.circle.fill" : "xmark.circle"
                        )
                        .foregroundStyle(agentHasAccessibility ? .green : .orange)
                        Label(
                            agentHasScreenRecording ? "Screen Recording" : "Screen Recording missing",
                            systemImage: agentHasScreenRecording ? "checkmark.circle.fill" : "xmark.circle"
                        )
                        .foregroundStyle(agentHasScreenRecording ? .green : .orange)
                    }
                    .font(.app(.caption))
                    .labelStyle(.titleAndIcon)
                }
            } header: {
                Text("Agent")
            } footer: {
                Text(
                    "Clicking, typing and reading the screen need Accessibility and Screen Recording. Plugins are JSON files that become voice tools; the agent can also write them itself."
                )
                .font(.app(.caption))
                .foregroundStyle(.secondary)
            }

            MCPServersSection()

            Section("Pasting") {
                Toggle(isOn: $matchWritingStyleToApp) {
                    HStack(spacing: 2) {
                        Text("Match Writing Style to the App")
                        InfoTip(
                            "Dictation adapts to where it is pasted: full sentences in Mail, short and casual in Slack or Messages, lists in Notes, code-form names in editors. Modes with a custom prompt still take priority."
                        )
                    }
                }

                ExpandableSettingsRow(
                    isExpanded: $isRestoreClipboardExpanded,
                    isEnabled: $restoreClipboardAfterPaste,
                    label: "Keep Clipboard Content",
                    infoMessage:
                        "VoxOS temporarily uses the clipboard to paste transcription. When enabled, it restores your previous clipboard content after the selected delay. When disabled, the pasted transcription stays on your clipboard."
                ) {
                    Picker("Restore Delay", selection: $clipboardRestoreDelay) {
                        Text("250ms").tag(0.25)
                        Text("500ms").tag(0.5)
                        Text("1s").tag(1.0)
                        Text("2s").tag(2.0)
                        Text("3s").tag(3.0)
                        Text("4s").tag(4.0)
                        Text("5s").tag(5.0)
                    }
                }

                Picker(selection: $pasteMethodRawValue) {
                    ForEach(PasteMethod.allCases) { method in
                        Text(method.displayName).tag(method.rawValue)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Paste Method")
                        InfoTip(
                            "Default uses simulated Cmd+V key events. AppleScript can help when custom keyboard layouts do not paste correctly."
                        )
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: pasteMethodRawValue) { _, newValue in
                    guard let method = PasteMethod(rawValue: newValue) else {
                        pasteMethodRawValue = PasteMethod.standard.rawValue
                        return
                    }
                    PasteMethod.setCurrent(method)
                }
            }

            Section("Interface") {
                Picker("Appearance", selection: $appAppearancePreference) {
                    ForEach(AppAppearancePreference.allCases) { preference in
                        Text(preference.displayName).tag(preference)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: appAppearancePreference) { _, newValue in
                    newValue.apply()
                }

                Picker("Language", selection: $appLanguagePreference) {
                    ForEach(AppLanguagePreference.availableOptions) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: appLanguagePreference) { oldValue, newValue in
                    guard oldValue != newValue else { return }
                    let normalizedValue = AppLanguagePreference.normalizedRawValue(newValue)
                    if normalizedValue != newValue {
                        appLanguagePreference = normalizedValue
                        return
                    }
                    AppLanguagePreference.apply(rawValue: normalizedValue)
                    showLanguageRestartAlert = true
                }

                Picker("Recorder Position", selection: $recorderUIManager.recorderPanelStyle) {
                    ForEach(RecorderPanelStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .pickerStyle(.menu)

                Toggle(isOn: $showLiveTranscript) {
                    HStack(spacing: 4) {
                        Text("Live Text Display")
                        InfoTip("Shows live text while recording with realtime models.")
                    }
                }
            }

            Section("General") {
                Toggle("Hide Dock Icon", isOn: $menuBarManager.isMenuBarOnly)

                Toggle(
                    String(localized: "Launch at Login"),
                    isOn: Binding(
                        get: { launchAtLoginManager.isEnabled },
                        set: { launchAtLoginManager.setEnabled($0) }
                    )
                )
                .disabled(launchAtLoginManager.isUpdating)

                Toggle(
                    "Automatically Check for Updates",
                    isOn: Binding(
                        get: { updaterViewModel.checksForUpdatesWhenDashboardAppears },
                        set: { updaterViewModel.setChecksForUpdatesWhenDashboardAppears($0) }
                    ))

                Toggle("Show Announcements", isOn: $enableAnnouncements)
                    .onChange(of: enableAnnouncements) { _, newValue in
                        if newValue {
                            AnnouncementsService.shared.start()
                        } else {
                            AnnouncementsService.shared.stop()
                        }
                    }

                HStack {
                    Button("Check for Updates") {
                        updaterViewModel.checkForUpdates()
                    }
                    .disabled(!updaterViewModel.canCheckForUpdates)

                    Button("Reset Onboarding") {
                        showResetOnboardingAlert = true
                    }
                }
            }

            Section {
                LabeledContent("Export Settings") {
                    Button("Export") {
                        Task {
                            await ImportExportService.shared.exportSettings(
                                enhancementService: enhancementService,
                                recordingShortcutManager: recordingShortcutManager,
                                menuBarManager: menuBarManager,
                                mediaController: mediaController,
                                playbackController: playbackController,
                                recorderUIManager: recorderUIManager,
                                modelContext: modelContext
                            )
                        }
                    }
                }

                LabeledContent("Import Settings") {
                    Button("Import") {
                        ImportExportService.shared.importSettings(
                            enhancementService: enhancementService,
                            recordingShortcutManager: recordingShortcutManager,
                            menuBarManager: menuBarManager,
                            mediaController: mediaController,
                            playbackController: playbackController,
                            recorderUIManager: recorderUIManager,
                            modelContext: modelContext,
                            transcriptionModelManager: transcriptionModelManager
                        )
                    }
                }
            } header: {
                Text("Backup")
            } footer: {
                Text("Export all settings, or choose specific categories when importing a backup.")
            }

            Section("Diagnostics") {
                DiagnosticsSettingsView()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .alert("Reset Onboarding", isPresented: $showResetOnboardingAlert) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                DispatchQueue.main.async {
                    hasCompletedOnboardingV2 = false
                }
            }
        } message: {
            Text("You'll see the introduction screens again the next time you launch the app.")
        }
        .alert("Restart VoxOS to Apply Language", isPresented: $showLanguageRestartAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your language change will take full effect after you quit and reopen VoxOS.")
        }
    }

    private static let defaultCancelRecordingShortcut = Shortcut.key(
        keyCode: UInt16(kVK_Escape),
        modifierFlags: []
    )

    @ViewBuilder
    private func shortcutModePicker(binding: Binding<RecordingShortcutManager.Mode>) -> some View {
        Picker("", selection: binding) {
            ForEach(RecordingShortcutManager.Mode.allCases, id: \.self) { mode in
                Text(mode.displayName).tag(mode)
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}

extension Text {
    func settingsDescription() -> some View {
        self
            .font(.app(size: 12, weight: .regular))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
