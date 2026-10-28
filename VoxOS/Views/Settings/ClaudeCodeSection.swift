import SwiftUI

/// Settings → Claude Code: show running sessions in the notch and answer their permission
/// requests there.
struct ClaudeCodeSection: View {
    @ObservedObject private var integration = ClaudeCodeIntegration.shared
    @AppStorage(DefaultsKeys.claudeCodeEnabled) private var enabled = false
    @AppStorage(DefaultsKeys.claudeCodeApprovalsEnabled) private var approvalsEnabled = true
    @AppStorage(DefaultsKeys.claudeCodeStatusEnabled) private var statusEnabled = false
    @AppStorage(DefaultsKeys.claudeCodeQuietInTerminal) private var quietInTerminal = true
    @AppStorage(DefaultsKeys.claudeCodeRepliesEnabled) private var repliesEnabled = false
    @AppStorage(DefaultsKeys.claudeCodeSpeaksReplies) private var speaksReplies = false
    @AppStorage(DefaultsKeys.claudeCodeUsageEnabled) private var usageEnabled = false
    @AppStorage(DefaultsKeys.codexNotifyEnabled) private var codexEnabled = false
    @ObservedObject private var usage = ClaudeCodeUsage.shared

    var body: some View {
        Section {
            Toggle(
                "Show Claude Code in the Notch",
                isOn: Binding(get: { enabled }, set: { integration.setEnabled($0) }))

            if enabled {
                Toggle(
                    "Allow or Deny Requests from the Notch",
                    isOn: Binding(get: { approvalsEnabled }, set: { integration.setApprovalsEnabled($0) }))

                if approvalsEnabled {
                    Toggle(isOn: $quietInTerminal) {
                        HStack(spacing: 2) {
                            Text("Quiet While Its Terminal Is in Front")
                            InfoTip(
                                "When the app running the session is in front, a request waits as a small band with a count instead of a card, since the terminal is asking too. Click the band to answer in the notch."
                            )
                        }
                    }
                }

                Toggle(isOn: $repliesEnabled) {
                    HStack(spacing: 2) {
                        Text("Show Claude's Reply When a Turn Ends")
                        InfoTip(
                            "A card with Claude's last message for a few seconds when a session finishes, with a button to hear it. Not while that session's terminal is in front."
                        )
                    }
                }
                if repliesEnabled {
                    Toggle("Read Replies Aloud", isOn: $speaksReplies)
                }

                Toggle(isOn: Binding(get: { usageEnabled }, set: { integration.setUsageEnabled($0) })) {
                    HStack(spacing: 2) {
                        Text("Show Usage Limits and Costs")
                        InfoTip(
                            "Your 5-hour and weekly limits, with a notice in the notch at 80% and 95%, and what sessions cost each day. Your status line command is kept and still draws the status line; VoxOS only gets a copy of its input. Switching this off puts your status line back as it was."
                        )
                    }
                }
                if usageEnabled { usageSummary }

                if CodexNotify.codexInstalled {
                    Toggle(isOn: Binding(get: { codexEnabled }, set: { integration.setCodexEnabled($0) })) {
                        HStack(spacing: 2) {
                            Text("Codex: Notice When a Turn Ends")
                            InfoTip(
                                "Adds a notify line to ~/.codex/config.toml (after a backup) that tells VoxOS when a Codex turn ends. A notify of your own is never replaced. Codex cannot hand approvals to another app, so only the end of a turn shows."
                            )
                        }
                    }
                }

                Toggle("Show When a Session Is Working", isOn: $statusEnabled)

                HStack(spacing: 10) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusText)
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if integration.installState != .installed {
                        Button("Install Hooks") { integration.installHooks() }
                    }
                    Button("Open settings.json") {
                        NSWorkspace.shared.open(ClaudeCodeHooks.userSettingsURL)
                    }
                    .disabled(!FileManager.default.fileExists(atPath: ClaudeCodeHooks.userSettingsURL.path))
                }
                .controlSize(.small)
            }

            if let problem = integration.problem {
                Text(problem)
                    .font(.app(.caption))
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Claude Code")
        } footer: {
            Text(
                "Adds hooks to ~/.claude/settings.json that report to VoxOS on this Mac only (127.0.0.1). A request still shows in the terminal too; whichever you answer first wins. Turning this off removes the hooks."
            )
            .font(.app(.caption))
            .foregroundStyle(.secondary)
        }
        .onAppear { integration.refreshInstallState() }
    }

    /// The limits as last reported, and costs for today and the week.
    private var usageSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let five = usage.fiveHour {
                Text(
                    "5-hour: \(Int(five.percent))% · resets \(five.resetsAt.formatted(date: .omitted, time: .shortened))"
                )
            }
            if let week = usage.sevenDay {
                Text(
                    "Weekly: \(Int(week.percent))% · resets \(week.resetsAt.formatted(date: .abbreviated, time: .omitted))"
                )
            }
            Text(
                "Cost today \(usage.total(days: 1).formatted(.currency(code: "USD"))) · last 7 days \(usage.total(days: 7).formatted(.currency(code: "USD")))"
            )
            if usage.fiveHour == nil {
                Text("Limits show after Claude Code's next reply, for Claude.ai plans.")
            }
        }
        .font(.app(.caption))
        .foregroundStyle(.secondary)
    }

    private var statusColor: Color {
        switch integration.bridgeState {
        case .listening: return integration.installState == .installed ? .green : .yellow
        case .starting: return .yellow
        case .failed: return .red
        case .stopped: return .gray
        }
    }

    private var statusText: String {
        switch integration.bridgeState {
        case .failed(let reason):
            return reason
        case .stopped:
            return String(localized: "Not listening")
        case .starting:
            return String(localized: "Starting…")
        case .listening(let port):
            switch integration.installState {
            case .installed: return String(localized: "Listening on 127.0.0.1:\(String(port))")
            case .outdated: return String(localized: "Hooks are out of date")
            case .notInstalled: return String(localized: "Hooks are not installed")
            }
        }
    }
}
