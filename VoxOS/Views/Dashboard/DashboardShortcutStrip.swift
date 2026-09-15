import SwiftUI

/// "How do I use this" at a glance: the live recording shortcut and what a hold, a tap and a
/// double-tap do. Reads the stored shortcuts so it never lies about the keys.
struct DashboardShortcutStrip: View {
    @ObservedObject private var modeManager = ModeManager.shared

    private var primary: Shortcut? { ShortcutStore.shortcut(for: .primaryRecording) }
    private var agentShortcut: Shortcut? { ShortcutStore.shortcut(for: .mode(StarterModeCatalog.agentId)) }
    private var agentTap: Shortcut? { ShortcutStore.shortcut(for: .agentDoubleTap) }
    private var hasAgentMode: Bool {
        modeManager.getConfiguration(with: StarterModeCatalog.agentId)?.isEnabled == true
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], alignment: .leading, spacing: 12) {
            if let primary {
                chip(keys: [primary.displayString], title: "Hold to dictate", detail: "Release to paste")
                chip(keys: [primary.displayString], title: "Tap for hands-free", detail: "Tap again to stop")
            }
            if let agentTap {
                chip(
                    keys: [agentTap.displayString, agentTap.displayString],
                    title: "Double-tap for Agent",
                    detail: "Say what to do; it sends when you pause")
            }
            if let agentShortcut, hasAgentMode {
                chip(keys: [agentShortcut.displayString], title: "Hold for Agent", detail: "Direct to Agent mode")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(keys: [String], title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    Text(key)
                        .font(.app(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.primary)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .frame(minWidth: 30, minHeight: 26)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(AppTheme.Surface.subtle)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(AppTheme.Border.control, lineWidth: 1)
                        )
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 14)
    }
}
