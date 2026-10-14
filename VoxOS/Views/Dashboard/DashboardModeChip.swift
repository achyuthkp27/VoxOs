import SwiftUI

/// The mode VoxOS dictates with right now, as a compact chip in the Dashboard header: its
/// spectrum dot, its name and a chevron. Clicking opens Modes to switch or edit.
struct DashboardModeChip: View {
    @ObservedObject private var modeManager = ModeManager.shared
    @State private var isHovering = false

    var body: some View {
        Button(action: openModes) {
            HStack(spacing: 8) {
                Text("Mode")
                    .font(.appMono(size: 10, weight: .medium))
                    .foregroundStyle(AppTheme.Text.muted)
                    .textCase(.uppercase)
                    .tracking(0.6)

                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)

                Text(verbatim: title)
                    .font(.app(size: 13, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 180, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.app(size: 9, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                Capsule(style: .continuous)
                    .fill(isHovering ? AppTheme.Surface.control : AppTheme.Surface.card)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(AppTheme.Border.card, lineWidth: 1)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .help("Change mode")
        .accessibilityLabel(Text("Current mode: \(title)"))
        .accessibilityHint("Opens Modes to switch or edit modes")
        .animation(.easeOut(duration: 0.2), value: modeManager.currentEffectiveConfiguration?.id)
    }

    private var title: String {
        modeManager.currentEffectiveConfiguration?.name ?? String(localized: "Add a mode")
    }

    private var dotColor: Color {
        guard let mode = modeManager.currentEffectiveConfiguration else { return AppTheme.Text.muted }
        return ModeSpectrum.color(for: mode, in: modeManager.configurations)
    }

    private func openModes() {
        MainWindowNavigation.shared.navigate(to: .modes)
    }
}
