import SwiftUI

/// Settings → MCP Servers: what is connected, and the three things a user does with it —
/// edit the config, import Claude Desktop's servers, reload.
struct MCPServersSection: View {
    @State private var statuses: [AgentMCP.ServerStatus] = AgentMCP.statuses()
    @State private var importMessage: String?

    var body: some View {
        Section {
            if statuses.isEmpty {
                Text("No servers yet. Add them to the config file, or import the ones Claude Desktop already uses.")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(statuses) { status in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(color(for: status))
                            .frame(width: 8, height: 8)
                        Text(status.name)
                        Spacer()
                        Text(detail(for: status))
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(detail(for: status))
                    }
                }
            }

            HStack(spacing: 8) {
                Button("Open Config") {
                    AgentMCP.ensureConfigFile()
                    NSWorkspace.shared.open(AgentMCP.configURL)
                }
                Button("Import from Claude Desktop") {
                    let result = AgentMCP.importClaudeDesktopConfig()
                    if let error = result.error {
                        importMessage = error
                    } else if result.imported.isEmpty {
                        importMessage = "Everything from Claude Desktop is already here."
                    } else {
                        importMessage = "Imported \(result.imported.joined(separator: ", "))."
                        AgentMCP.reload()
                    }
                    refresh()
                }
                .disabled(!FileManager.default.fileExists(atPath: AgentMCP.claudeDesktopConfigURL.path))
                Spacer()
                Button("Reload") {
                    AgentMCP.reload()
                    refresh()
                }
            }
            .controlSize(.small)

            if let importMessage {
                Text(importMessage)
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("MCP Servers")
        } footer: {
            Text("Each server's tools become Agent tools. Tools a server marks read-only run freely; everything else follows the Control Mode above. Remote (URL) servers are not supported yet.")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
        }
        .onReceive(NotificationCenter.default.publisher(for: AgentMCP.statusDidChange)) { _ in
            refresh()
        }
        .onAppear {
            AgentMCP.warmUp()
            refresh()
        }
    }

    private func refresh() {
        statuses = AgentMCP.statuses()
    }

    private func color(for status: AgentMCP.ServerStatus) -> Color {
        if status.unsupportedReason != nil { return .gray }
        switch status.state {
        case .ready: return .green
        case .starting: return .yellow
        case .failed: return .red
        case .idle: return .gray
        }
    }

    private func detail(for status: AgentMCP.ServerStatus) -> String {
        if let reason = status.unsupportedReason { return reason }
        switch status.state {
        case .ready: return status.toolCount == 1 ? "1 tool" : "\(status.toolCount) tools"
        case .starting: return "Starting…"
        case .failed(let reason): return reason
        case .idle: return "Not started"
        }
    }
}
