import Carbon.HIToolbox
import Cocoa
import SwiftUI

/// The Voice Assistant page: shortcuts, the recorder, pasting, transcription, the Agent, MCP and
/// system audio.
struct VoiceSettingsPage: View {
    @EnvironmentObject private var recordingShortcutManager: RecordingShortcutManager
    @EnvironmentObject private var recorderUIManager: RecorderUIManager
    @ObservedObject private var systemAudioController = SystemAudioCaptureController.shared
    @AppStorage(DefaultsKeys.voiceAssistantEnabled) private var voiceMaster = true
    @AppStorage(DefaultsKeys.restoreClipboardAfterPaste) private var restoreClipboardAfterPaste = true
    @AppStorage(DefaultsKeys.clipboardRestoreDelay) private var clipboardRestoreDelay = 2.0
    @AppStorage(PasteMethod.userDefaultsKey) private var pasteMethodRawValue = PasteMethod.standard.rawValue
    @AppStorage(RecorderDisplaySettingsKeys.showLiveTranscript) private var showLiveTranscript = true
    @AppStorage(DefaultsKeys.edgeHistoryEnabled) private var edgeHistoryEnabled = true
    @AppStorage(DefaultsKeys.identifySpeakers) private var identifySpeakers = false
    @AppStorage(SystemAudioCaptureController.DefaultsKey.bufferEnabled) private var systemAudioBufferEnabled = false
    @AppStorage(SystemAudioCaptureController.DefaultsKey.bufferSeconds) private var systemAudioBufferSeconds =
        SystemAudioCaptureController.defaultBufferSeconds
    @AppStorage(SystemAudioCaptureController.DefaultsKey.pasteAtCursor) private var systemAudioPasteAtCursor = true
    @AppStorage(SystemAudioCaptureController.DefaultsKey.saveToHistory) private var systemAudioSaveToHistory = true
    @AppStorage(AgentControlMode.userDefaultsKey) private var agentControlModeRaw = AgentControlMode.takeover.rawValue
    @AppStorage(AgentShell.allowRiskyKey) private var agentAllowRiskyShell = false
    @AppStorage(AgentAutoSend.enabledKey) private var agentAutoSendEnabled = true
    @AppStorage(AgentAutoSend.pauseKey) private var agentAutoSendPause = AgentAutoSend.Pause.normal.rawValue
    @AppStorage(AgentAutoClose.enabledKey) private var agentAutoCloseEnabled = true
    @AppStorage(DictationSend.stopWhenQuietKey) private var dictationStopWhenQuiet = false
    @AppStorage(DictationSend.pressReturnKey) private var dictationPressReturn = false
    @AppStorage(WritingDestination.isEnabledKey) private var matchWritingStyleToApp = true
    @State private var cancelRecordingShortcutRecorderResetID = 0
    @State private var isMiddleClickExpanded = false
    @State private var isSystemAudioBufferExpanded = false
    @State private var isRestoreClipboardExpanded = false
    @State private var agentHasAccessibility = ProcessIdentity.isTestHost ? false : AXIsProcessTrusted()
    @State private var agentHasScreenRecording = CGPreflightScreenCaptureAccess()
    @State private var settingsSearch = ""

    private var search: SettingsSearchMatcher { SettingsSearchMatcher(query: settingsSearch) }

    private static let sections: [SettingsSection] = [
        .shortcuts, .additionalShortcuts, .recorder, .pasting, .transcription, .agent, .mcp, .systemAudio,
    ]

    var body: some View {
        SettingsForm(query: $settingsSearch, hasMatches: search.matchesAny(Self.sections)) {
            if !search.isFiltering {
                Section {
                    Toggle(
                        "Voice Assistant",
                        isOn: Binding(get: { voiceMaster }, set: { MasterSwitches.setVoiceEnabled($0) }))
                } footer: {
                    Text("Off, the shortcuts below start nothing: no dictation, no Agent. They are kept as they are.")
                        .settingsCaption()
                }
            }

            if search.matches(.shortcuts) {
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
            }

            if search.matches(.additionalShortcuts) {
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
                        ShortcutRecorder(action: .undoLastPaste) {
                            recordingShortcutManager.updateShortcutStatus()
                        }
                        .controlSize(.small)
                    } label: {
                        HStack(spacing: 2) {
                            Text("Undo Last Paste")
                            InfoTip(
                                "Takes back the text VoxOS just pasted, as ⌘Z would, while that app is still in front. Saying “scratch that” on its own does the same."
                            )
                        }
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
            }

            if search.matches(.recorder) {
                Section {
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
                    Toggle(isOn: $edgeHistoryEnabled) {
                        HStack(spacing: 2) {
                            Text("Left-Edge History")
                            InfoTip(
                                "Reveals recent transcriptions when the pointer reaches the left edge of the screen. Watching for that means tracking every mouse movement, so turning it off measurably reduces battery use. Takes effect after a restart."
                            )
                        }
                    }
                } header: {
                    Text("Recorder")
                }
            }

            if search.matches(.pasting) {
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
            }

            if search.matches(.transcription) {
                Section("Transcription") {
                    Toggle(isOn: $identifySpeakers) {
                        HStack(spacing: 2) {
                            Text("Identify Speakers")
                            InfoTip(
                                "Labels each turn in an imported recording with who spoke. Needs a Parakeet model — it is the only one that reports word timings, which speaker labels are built from. Downloads a speaker model the first time it runs."
                            )
                        }
                    }
                }
            }

            if search.matches(.agent) {
                Section {
                    Picker("Control Mode", selection: $agentControlModeRaw) {
                        ForEach(AgentControlMode.allCases) { mode in
                            Text(mode.displayName).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.menu)

                    Text((AgentControlMode(rawValue: agentControlModeRaw) ?? .takeover).summary)
                        .settingsCaption()

                    AgentAppModeOverridesRows()

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

                    Toggle(isOn: $agentAutoCloseEnabled) {
                        HStack(spacing: 2) {
                            Text("Close After Opening Something")
                            InfoTip(
                                "When a request only opens an app or page (“open Slack”), the Agent panel closes by itself a moment after it does. It stays open for answers, errors, questions, and anything that did more than open."
                            )
                        }
                    }

                    Toggle(isOn: $agentAllowRiskyShell) {
                        HStack(spacing: 2) {
                            Text("Allow Risky Shell Commands")
                            InfoTip(
                                "Commands that look destructive (rm -rf, sudo, disk formatting, piping downloads into a shell…) are refused unless this is on. When on, they run and the agent tells you what it did."
                            )
                        }
                    }

                    HStack(spacing: 2) {
                        Text("Main and fallback model are set in AI Models.")
                            .settingsCaption()
                        InfoTip(
                            "AI Models → Main & Fallback Model. The fallback is tried when the main model is rate-limited, down, unreachable or answers with nothing. Off by default: your text only goes to models you pick there."
                        )
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
                    .settingsCaption()
                }
            }

            if search.matches(.mcp) {
                MCPServersSection()
            }

            if search.matches(.systemAudio) {
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
                    // On one row rather than the Section: a Section applies its modifiers to every
                    // row, so the buffer would be re-synced once per row for a single change.
                    .onChange(of: systemAudioBufferEnabled) { _, _ in
                        Task { await systemAudioController.syncBufferingWithPreference() }
                    }
                    .onChange(of: systemAudioBufferSeconds) { _, _ in
                        Task { await systemAudioController.syncBufferingWithPreference() }
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
                    .settingsCaption()
                }
            }
        }
        .onAppear(perform: refreshAgentPermissions)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Permissions are granted in System Settings, so they change while VoxOS is in the
            // background; re-reading on activation shows the grant without reopening Settings.
            refreshAgentPermissions()
        }
    }

    private func refreshAgentPermissions() {
        agentHasAccessibility = ProcessIdentity.isTestHost ? false : AXIsProcessTrusted()
        agentHasScreenRecording = CGPreflightScreenCaptureAccess()
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
