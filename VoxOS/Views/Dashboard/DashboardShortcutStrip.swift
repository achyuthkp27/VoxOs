import SwiftUI

/// Quick actions as one quiet line at the foot of the page: each live recording shortcut as a
/// keycap with what it does. No cards, so it reminds without competing with the stats. Reads the
/// stored shortcuts so it never lies about the keys; scrolls sideways when the window is narrow.
struct DashboardShortcutStrip: View {
    @ObservedObject private var modeManager = ModeManager.shared

    private struct Item: Identifiable {
        let id: String
        let keys: [String]
        let title: LocalizedStringKey
    }

    private var items: [Item] {
        var items: [Item] = []
        if let primary = ShortcutStore.shortcut(for: .primaryRecording) {
            items.append(Item(id: "hold", keys: [primary.displayString], title: "Hold to dictate"))
            items.append(Item(id: "tap", keys: [primary.displayString], title: "Tap for hands-free"))
        }
        if let dictateAndSend = ShortcutStore.shortcut(for: .dictateAndSend) {
            items.append(Item(id: "send", keys: [dictateAndSend.displayString], title: "Dictate and send"))
        }
        if let agentTap = ShortcutStore.shortcut(for: .agentDoubleTap) {
            items.append(
                Item(
                    id: "agent-tap", keys: [agentTap.displayString, agentTap.displayString],
                    title: "Double-tap for Agent"))
        } else if let agent = ShortcutStore.shortcut(for: .mode(StarterModeCatalog.agentId)),
            modeManager.getConfiguration(with: StarterModeCatalog.agentId)?.isEnabled == true
        {
            items.append(Item(id: "agent-hold", keys: [agent.displayString], title: "Hold for Agent"))
        }
        return items
    }

    var body: some View {
        let items = self.items

        HStack(alignment: .center, spacing: 16) {
            Text("Quick actions")
                .font(.appMono(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)

            if items.isEmpty {
                Text("No recording shortcut is set. Add one in Settings to start dictating.")
                    .font(.app(size: 12, weight: .regular))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .lineLimit(1)
            } else {
                ViewThatFits(in: .horizontal) {
                    row(items)
                    ScrollView(.horizontal, showsIndicators: false) {
                        row(items)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ items: [Item]) -> some View {
        HStack(spacing: 20) {
            ForEach(items) { item in
                HStack(spacing: 8) {
                    HStack(spacing: 3) {
                        ForEach(Array(item.keys.enumerated()), id: \.offset) { _, key in
                            keycap(key)
                        }
                    }
                    Text(item.title)
                        .font(.app(size: 12, weight: .regular))
                        .foregroundStyle(AppTheme.Text.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .accessibilityElement(children: .combine)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func keycap(_ key: String) -> some View {
        Text(verbatim: key)
            .font(.appMono(size: 11, weight: .semibold))
            .foregroundStyle(AppTheme.Text.primary)
            .fixedSize()
            .padding(.horizontal, 6)
            .frame(minWidth: 24, minHeight: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AppTheme.Surface.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(AppTheme.Border.control, lineWidth: 1)
            )
    }
}
