import SwiftUI

/// Settings → Claude Code: show running sessions in the notch and answer their permission
/// requests there.
struct ClaudeCodeSection: View {
    @ObservedObject private var integration = ClaudeCodeIntegration.shared
    @AppStorage(DefaultsKeys.claudeCodeEnabled) private var enabled = false
    @AppStorage(DefaultsKeys.claudeCodeApprovalsEnabled) private var approvalsEnabled = true
    @AppStorage(DefaultsKeys.claudeCodeStatusEnabled) private var statusEnabled = false
    @AppStorage(DefaultsKeys.claudeCodeQuietInTerminal) private var quietInTerminal = true

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
