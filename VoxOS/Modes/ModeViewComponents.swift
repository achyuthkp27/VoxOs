import SwiftUI

struct VoxOSButton: View {
    let title: LocalizedStringKey
    let action: () -> Void
    var isDisabled: Bool = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.app(.headline))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isDisabled ? AppTheme.Accent.disabled : AppTheme.Accent.primary)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

struct ModeEmptyStateView: View {
    let action: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.circle.fill")
                .font(.app(size: 48, weight: .regular))
                .foregroundColor(.secondary)

            Text("No Modes")
                .font(.app(.title2))
                .fontWeight(.semibold)

            Text("Add customized modes for different contexts")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VoxOSButton(
                title: "Add New Mode",
                action: action
            )
            .frame(maxWidth: 250)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ModeConfigurationsGrid: View {
    @ObservedObject var modeManager: ModeManager
    let onEditConfig: (ModeConfig) -> Void
    @EnvironmentObject var enhancementService: AIEnhancementService

    var body: some View {
        LazyVStack(spacing: 12) {
            ForEach($modeManager.configurations) { $config in
                ConfigurationRow(
                    config: $config,
                    isEditing: false,
                    modeManager: modeManager,
                    onEditConfig: onEditConfig
                )
            }
        }
    }
}

struct DefaultModeIndicator: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark.seal.fill")
                .font(.app(size: 11, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.primary)

            Text("Default")
                .font(.app(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.leading, 7)
        .padding(.trailing, 9)
        .frame(height: 24)
        .background {
            Capsule()
                .fill(AppTheme.Surface.card)
        }
        .overlay {
            Capsule()
                .strokeBorder(AppTheme.Border.control, lineWidth: 0.5)
        }
        .contentShape(Capsule())
        .help("Default mode is used when no app or website matches")
    }
}

struct ConfigurationRow: View {
    private struct TranscriptionModelMetadata {
        let label: String
        let isWarning: Bool
    }

    @Binding var config: ModeConfig
    let isEditing: Bool
    let modeManager: ModeManager
    let onEditConfig: (ModeConfig) -> Void
    @EnvironmentObject var enhancementService: AIEnhancementService
    @EnvironmentObject var transcriptionModelManager: TranscriptionModelManager
    @State private var isHovering = false

    private let maxAppIconsToShow = 5

    private var selectedPrompt: CustomPrompt? {
        guard let promptId = config.selectedPrompt,
            let uuid = UUID(uuidString: promptId)
        else { return nil }
        return enhancementService.allPrompts.first { $0.id == uuid }
    }

    private var transcriptionModelMetadata: TranscriptionModelMetadata {
        switch ModeRuntimeResolver.transcriptionModelResolution(
            mode: config,
            transcriptionModelManager: transcriptionModelManager
        ) {
        case .available(_, let model):
            return TranscriptionModelMetadata(
                label: model.displayName,
                isWarning: false
            )
        case .noMode, .noSelection, .modelNotFound, .unavailable:
            return TranscriptionModelMetadata(
                label: String(localized: "Unavailable"),
                isWarning: true
            )
        }
    }

    private var selectedLanguage: String? {
        if let langCode = config.selectedLanguage {
            if langCode == "auto" { return String(localized: "Auto") }
            if langCode == "en" { return String(localized: "English") }

            if let modelName = config.selectedTranscriptionModelName,
                let model = transcriptionModelManager.allAvailableModels.first(where: { $0.name == modelName }),
                let langName = TranscriptionLanguageSupport.languages(
                    for: model, realtimeEnabled: config.isRealtimeTranscriptionEnabled)[langCode]
            {
                return langName
            }
            return langCode.uppercased()
        }
        return "Default"
    }

    private var appCount: Int { return config.allAppConfigs.count }
    private var websiteCount: Int { return config.allURLConfigs.count }

    private var websiteText: String {
        if websiteCount == 0 { return "" }
        return String(localized: "\(websiteCount) Websites")
    }

    private var appText: String {
        if appCount == 0 { return "" }
        return String(localized: "\(appCount) Apps")
    }

    private var extraAppsCount: Int {
        return max(0, appCount - maxAppIconsToShow)
    }

    private var visibleAppConfigs: [AppConfig] {
        return Array(config.allAppConfigs.prefix(maxAppIconsToShow))
    }

    private var editModeButton: some View {
        Button {
            onEditConfig(config)
        } label: {
            Text("Edit")
                .font(.app(.caption))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(AppTheme.Surface.control)
                )
                .overlay(
                    Capsule()
                        .stroke(AppTheme.Border.control, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help("Edit mode")
        .accessibilityLabel("Edit mode")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        ModeIconView(icon: config.icon, size: config.icon.kind == .emoji ? 20 : 16)
                    }
                    .frame(width: 40, height: 40)
                    .background(
                        AppCardBackground(isSelected: false, cornerRadius: AppTheme.Radius.pill)
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(config.name)
                            .font(.app(size: 15, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        HStack(spacing: 12) {
                            if appCount > 0 {
                                HStack(spacing: 4) {
                                    Image(systemName: "app.fill")
                                        .font(.app(size: 10, weight: .regular))
                                    Text(appText)
                                        .font(.app(.caption2))
                                }
                            }

                            if websiteCount > 0 {
                                HStack(spacing: 4) {
                                    Image(systemName: "globe")
                                        .font(.app(size: 10, weight: .regular))
                                    Text(websiteText)
                                        .font(.app(.caption2))
                                }
                            }
                        }
                        .padding(.top, 2)
                        .foregroundColor(.secondary)
                    }

                    Spacer()

                    if config.isDefault {
                        DefaultModeIndicator()
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    onEditConfig(config)
                }

                if !config.isDefault {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { config.isEnabled },
                            set: { newValue in
                                if newValue {
                                    modeManager.enableConfiguration(with: config.id)
                                } else {
                                    modeManager.disableConfiguration(with: config.id)
                                }
                            }
                        )
                    )
                    .toggleStyle(SwitchToggleStyle(tint: AppTheme.Accent.primary))
                    .labelsHidden()
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppMaterialCardBackground.fill)

            Divider()

            // Up to five capsules share this row; each label truncates (lineLimit 1) and the spacer
            // can collapse so a long model or prompt name never pushes the row past the card width.
            HStack(spacing: 8) {
                let modelMetadata = transcriptionModelMetadata
                HStack(spacing: 4) {
                    Image(systemName: "waveform")
                        .font(.app(size: 10, weight: .regular))
                    Text(modelMetadata.label)
                        .font(.app(.caption))
                        .lineLimit(1)
                }
                .foregroundStyle(modelMetadata.isWarning ? Color.white : Color.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(
                            modelMetadata.isWarning
                                ? Color.red.opacity(0.80) : AppTheme.Surface.control)
                )
                .overlay(
                    Capsule()
                        .stroke(
                            modelMetadata.isWarning
                                ? Color.red.opacity(0.80) : AppTheme.Border.control,
                            lineWidth: 0.5
                        )
                )

                if let language = selectedLanguage, language != "Default" {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .font(.app(size: 10, weight: .regular))
                        Text(language)
                            .font(.app(.caption))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(AppTheme.Surface.control)
                    )
                    .overlay(
                        Capsule()
                            .stroke(AppTheme.Border.control, lineWidth: 0.5)
                    )
                }

                if config.isAIEnhancementEnabled,
                    config.selectedAIProvider != AIProvider.localCLI.rawValue,
                    let modelName = config.selectedAIModel,
                    !modelName.isEmpty
                {
                    HStack(spacing: 4) {
                        Image(systemName: "cpu")
                            .font(.app(size: 10, weight: .regular))
                        // Truncated by width rather than by character count, so wide and narrow
                        // model names get the same room and the ellipsis is the system's.
                        MaxWidthLayout(maxWidth: 120) {
                            Text(modelName)
                                .font(.app(.caption))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(AppTheme.Surface.control)
                    )
                    .overlay(
                        Capsule()
                            .stroke(AppTheme.Border.control, lineWidth: 0.5)
                    )
                }

                if config.outputMode != .paste {
                    HStack(spacing: 4) {
                        Image(systemName: config.outputMode.iconName)
                            .font(.app(size: 10, weight: .regular))
                        Text(config.outputMode.displayName)
                            .font(.app(.caption))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(AppTheme.Surface.control)
                    )
                    .overlay(
                        Capsule()
                            .stroke(AppTheme.Border.control, lineWidth: 0.5)
                    )
                }

                if config.outputMode == .paste && config.autoSendKey.isEnabled {
                    HStack(spacing: 4) {
                        Image(systemName: "keyboard")
                            .font(.app(size: 10, weight: .regular))
                        Text(config.autoSendKey.displayName)
                            .font(.app(.caption))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(AppTheme.Surface.control)
                    )
                    .overlay(
                        Capsule()
                            .stroke(AppTheme.Border.control, lineWidth: 0.5)
                    )
                }
                if config.isAIEnhancementEnabled {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.app(size: 10, weight: .regular))
                        Text(
                            config.selectedAIProvider == AIProvider.voxOSRefine.rawValue
                                ? VoxOSRefineService.providerName
                                : selectedPrompt?.title ?? "AI"
                        )
                        .font(.app(.caption))
                        .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(AppTheme.Surface.control)
                    )
                    .overlay(
                        Capsule()
                            .stroke(AppTheme.Border.control, lineWidth: 0.5)
                    )
                }

                Spacer(minLength: 0)

                // Always laid out and only faded, so hovering a row does not reflow its chips.
                editModeButton
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
                    .accessibilityHidden(!isHovering)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onEditConfig(config)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 16)
            .background(AppTheme.Surface.card)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(
                    AppMaterialCardBackground.border(for: isEditing),
                    lineWidth: AppMaterialCardBackground.lineWidth(for: isEditing)
                )
        }
        .opacity(config.isEnabled ? 1.0 : 0.70)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

}

struct ModeAppIcon: View {
    let bundleId: String

    var body: some View {
        if let icon = TriggerAppIconCache.shared.icon(for: bundleId) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: "app.fill")
                .font(.app(size: 14, weight: .regular))
                .foregroundColor(.secondary)
                .frame(width: 20, height: 20)
        }
    }
}

struct AppGridItem: View {
    let app: (url: URL, name: String, bundleId: String, icon: NSImage)
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 40, height: 40)
                    .cornerRadius(8)
                    .shadow(color: Color(NSColor.shadowColor).opacity(0.1), radius: 2, x: 0, y: 1)
                Text(app.name)
                    .font(.app(size: 10, weight: .regular))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 28)
            }
            .frame(width: 80, height: 80)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? AppTheme.Accent.fillSubtle : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? AppTheme.Accent.primary : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Caps its content's width without stretching it. `.frame(maxWidth:)` grows a short label up to
/// the maximum whenever more room is offered, which would leave empty space inside a chip.
private struct MaxWidthLayout: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = min(proposal.width ?? maxWidth, maxWidth)
        return content.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}
