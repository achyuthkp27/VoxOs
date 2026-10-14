import SwiftUI

/// Quick actions: the live recording shortcuts as keycap tiles, and what a hold, a tap and a
/// double-tap do. Reads the stored shortcuts so it never lies about the keys.
struct DashboardShortcutStrip: View {
    /// Tiles per row: three on a full-width page, fewer when the window is narrow.
    var columnCount: Int = 3

    @ObservedObject private var modeManager = ModeManager.shared

    private var primary: Shortcut? { ShortcutStore.shortcut(for: .primaryRecording) }
    private var agentShortcut: Shortcut? { ShortcutStore.shortcut(for: .mode(StarterModeCatalog.agentId)) }
    private var agentTap: Shortcut? { ShortcutStore.shortcut(for: .agentDoubleTap) }
    private var dictateAndSend: Shortcut? { ShortcutStore.shortcut(for: .dictateAndSend) }
    private var hasAgentMode: Bool {
        modeManager.getConfiguration(with: StarterModeCatalog.agentId)?.isEnabled == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DashboardLayout.labelSpacing) {
            DashboardSectionLabel("Quick actions")

            if primary == nil && dictateAndSend == nil && agentTap == nil {
                Text("No recording shortcut is set yet. Add one in Settings to start dictating.")
                    .font(.app(size: 12, weight: .regular))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .dashboardCard()
            } else {
                tiles
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tiles: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: DashboardLayout.columnSpacing, alignment: .top),
                count: max(columnCount, 1)
            ),
            alignment: .leading,
            spacing: DashboardLayout.columnSpacing
        ) {
            if let primary {
                tile(keys: [primary.displayString], title: "Hold to dictate", detail: "Release to paste")
                tile(keys: [primary.displayString], title: "Tap for hands-free", detail: "Tap again to stop")
            }
            if let dictateAndSend {
                tile(
                    keys: [dictateAndSend.displayString], title: "Dictate and send",
                    detail: "Presses Return after pasting")
            }
            if let agentShortcut, hasAgentMode {
                tile(keys: [agentShortcut.displayString], title: "Hold for Agent", detail: "Direct to Agent mode")
            }
            if let agentTap {
                tile(
                    keys: [agentTap.displayString, agentTap.displayString],
                    title: "Double-tap for Agent",
                    detail: "Say what to do; it sends when you pause")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A keycap row over a two-line caption, so the key reads first.
    private func tile(keys: [String], title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    Text(key)
                        .font(.appMono(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.primary)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .frame(minWidth: 30, minHeight: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(AppTheme.Surface.control)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(AppTheme.Border.control, lineWidth: 1)
                        )
                        .overlay(alignment: .bottom) {
                            // A keycap's lower lip, drawn as a hairline rather than a shadow.
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(AppTheme.Border.control)
                                .frame(height: 2)
                                .padding(.horizontal, 3)
                        }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.app(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primary)
                Text(detail)
                    .font(.app(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondary)
            }
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard(padding: 14)
        .accessibilityElement(children: .combine)
    }
}
