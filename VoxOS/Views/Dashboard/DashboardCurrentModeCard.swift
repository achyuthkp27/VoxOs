import SwiftUI

/// The mode VoxOS dictates with right now: its icon in its spectrum colour, its name, the speech
/// model and language it runs with, and the way to the Modes page.
struct DashboardCurrentModeCard: View {
    private static let tileSize: CGFloat = 40

    @ObservedObject private var modeManager = ModeManager.shared
    @EnvironmentObject private var enhancementService: AIEnhancementService
    @EnvironmentObject private var aiService: AIService
    @EnvironmentObject private var transcriptionModelManager: TranscriptionModelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardSectionLabel("Current mode")

            if let mode = modeManager.currentEffectiveConfiguration {
                content(for: mode)
            } else {
                emptyContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dashboardCard()
        .animation(.easeOut(duration: 0.2), value: modeManager.currentEffectiveConfiguration?.id)
    }

    private func content(for mode: ModeConfig) -> some View {
        let color = ModeSpectrum.color(for: mode, in: modeManager.configurations)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(0.18))
                    .frame(width: Self.tileSize, height: Self.tileSize)
                    .overlay {
                        ModeIconView(icon: mode.icon, size: 17, color: color)
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: mode.name)
                        .font(.app(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.primary)
                        .lineLimit(1)

                    Text(verbatim: settingsLine(for: mode))
                        .font(.appMono(size: 11, weight: .regular))
                        .foregroundStyle(AppTheme.Text.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.top, 14)

            Spacer(minLength: 14)

            Button("Change mode", action: openModes)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open Modes to switch or edit modes")
        }
        .accessibilityElement(children: .contain)
    }

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("No mode is on. Add one to choose how your words are written.")
                .font(.app(size: 13, weight: .regular))
                .foregroundStyle(AppTheme.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)

            Spacer(minLength: 14)

            Button("Add a mode", action: openModes)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }

    /// "<speech model> · <language>", leaving out whatever the mode does not set.
    private func settingsLine(for mode: ModeConfig) -> String {
        let facts = ModeListResolver(
            enhancementService: enhancementService,
            aiService: aiService,
            transcriptionModelManager: transcriptionModelManager
        ).facts(for: mode)

        let parts = [facts.transcriptionModel, facts.language].compactMap { $0 }
        guard !parts.isEmpty else { return String(localized: "No speech model set") }
        return parts.joined(separator: " · ")
    }

    private func openModes() {
        MainWindowNavigation.shared.navigate(to: .modes)
    }
}
