import AppKit
import SwiftUI

/// Settings → Agent, under Control Mode: apps that get their own mode. Rows only, so they
/// sit inside the Agent section right below the global picker.
struct AgentAppModeOverridesRows: View {
    /// bundle id → mode, mirrored from `AgentControlMode.appOverrides` and written back on change.
    @State private var overrides: [String: AgentControlMode] = [:]
    @State private var showingPicker = false

    var body: some View {
        Group {
            ForEach(sortedBundleIDs, id: \.self) { bundleID in
                HStack(spacing: 8) {
                    Image(nsImage: icon(for: bundleID))
                        .resizable()
                        .frame(width: 18, height: 18)
                    Text(AgentAppResolver.displayName(forBundleID: bundleID))
                        .lineLimit(1)
                    Spacer()
                    Picker("", selection: binding(for: bundleID)) {
                        ForEach(AgentControlMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    Button {
                        update(bundleID, nil)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Use the Control Mode above for this app")
                }
            }

            HStack(spacing: 2) {
                Button("Set a Mode for an App…") { showingPicker = true }
                    .controlSize(.small)
                InfoTip(
                    "Clicks, typing and keys follow the app in front; opening or switching to an app follows that app. Shell commands, scripts, files, plugins and MCP tools always use the Control Mode above."
                )
            }
        }
        .onAppear { overrides = AgentControlMode.appOverrides }
        .sheet(isPresented: $showingPicker) {
            AgentAppPickerSheet(excluded: Set(overrides.keys)) { bundleID in
                update(bundleID, AgentControlMode.current == .takeover ? .askBeforeAction : .takeover)
            }
        }
    }

    private var sortedBundleIDs: [String] {
        overrides.keys.sorted {
            AgentAppResolver.displayName(forBundleID: $0)
                .localizedCaseInsensitiveCompare(AgentAppResolver.displayName(forBundleID: $1)) == .orderedAscending
        }
    }

    private func binding(for bundleID: String) -> Binding<AgentControlMode> {
        Binding(
            get: { overrides[bundleID] ?? AgentControlMode.current },
            set: { update(bundleID, $0) }
        )
    }

    private func update(_ bundleID: String, _ mode: AgentControlMode?) {
        AgentControlMode.setOverride(mode, forBundleID: bundleID)
        overrides = AgentControlMode.appOverrides
    }

    private func icon(for bundleID: String) -> NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// A searchable list of installed apps; picking one adds it to the overrides.
private struct AgentAppPickerSheet: View {
    let excluded: Set<String>
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    /// The same cached app list the mode trigger picker uses; it scans off the main thread.
    @ObservedObject private var store = ModeFormWarmupStore.shared
    @State private var query = ""

    private var apps: [InstalledAppInfo]? { store.installedApps.isEmpty ? nil : store.installedApps }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose an App")
                .font(.headline)
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
            if let apps {
                List(filtered(apps), id: \.bundleId) { app in
                    Button {
                        onPick(app.bundleId)
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Image(nsImage: app.icon)
                                .resizable()
                                .frame(width: 18, height: 18)
                            Text(app.name)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 360, height: 420)
        .onAppear { store.loadInstalledAppsIfNeeded() }
    }

    private func filtered(_ apps: [InstalledAppInfo]) -> [InstalledAppInfo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return apps.filter {
            !excluded.contains($0.bundleId) && (q.isEmpty || $0.name.localizedCaseInsensitiveContains(q))
        }
    }
}
