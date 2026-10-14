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

/// The Modes list: one line for what every mode shares, then one compact row per mode in a
/// single grouped container. Rows only call out what makes their mode different.
struct ModeConfigurationsGrid: View {
    @ObservedObject var modeManager: ModeManager
    let onEditConfig: (ModeConfig) -> Void
    @EnvironmentObject var enhancementService: AIEnhancementService
    @EnvironmentObject var aiService: AIService
    @EnvironmentObject var transcriptionModelManager: TranscriptionModelManager

    // Read only so the shared line redraws when the main or Agent model changes in AI Models;
    // `AIModelRouting` itself is not observable.
    @AppStorage(DefaultsKeys.aiMainProvider) private var mainProvider = ""
    @AppStorage(DefaultsKeys.aiMainModel) private var mainModelName = ""
    @AppStorage(DefaultsKeys.aiAgentProvider) private var agentProvider = ""
    @AppStorage(DefaultsKeys.aiAgentModel) private var agentModelName = ""

    private var resolver: ModeListResolver {
        ModeListResolver(
            enhancementService: enhancementService,
            aiService: aiService,
            transcriptionModelManager: transcriptionModelManager
        )
    }

    var body: some View {
        let resolver = resolver
        let entries = modeManager.configurations.map {
            ModeListEntry(config: $0, facts: resolver.facts(for: $0))
        }
        let shared = ModeSharedSettings(facts: entries.map(\.facts))

        VStack(alignment: .leading, spacing: 18) {
            ModeSharedSettingsStrip(
                shared: shared,
                mainModel: resolver.mainModel,
                agentModel: resolver.agentModel
            )

            VStack(alignment: .leading, spacing: 8) {
                ModeListSectionLabel(count: entries.count)

                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 {
                            Divider()
                                .padding(.leading, ModeListRow.textInset)
                        }
                        ModeListRow(
                            config: entry.config,
                            tint: ModeSpectrum.color(for: entry.config, in: modeManager.configurations),
                            facts: entry.facts,
                            shared: shared,
                            promptTitle: resolver.promptTitle(for: entry.config),
                            modeManager: modeManager,
                            onEdit: { onEditConfig(entry.config) }
                        )
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(AppTheme.Surface.card)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(AppTheme.Border.card, lineWidth: 1)
                )
            }
        }
    }
}

private struct ModeListEntry: Identifiable {
    let config: ModeConfig
    let facts: ModeListFacts
    var id: UUID { config.id }
}

/// The mono eyebrow above the list, as on the other pages.
private struct ModeListSectionLabel: View {
    let count: Int

    var body: some View {
        HStack {
            Text(count == 1 ? String(localized: "1 mode") : String(localized: "\(count) modes"))
                .font(.appMono(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondary)
                .textCase(.uppercase)
                .tracking(0.6)
            Spacer()
            Text("Click a mode to edit it")
                .font(.app(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Text.muted)
        }
        .padding(.horizontal, 4)
    }
}

/// "All modes hear with … and write with …": the settings that would otherwise repeat on
/// every row, stated once.
private struct ModeSharedSettingsStrip: View {
    let shared: ModeSharedSettings
    let mainModel: String?
    let agentModel: String?

    var body: some View {
        if let sentence {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "waveform")
                    .font(.app(size: 12, weight: .semibold))
                    .foregroundStyle(AppTheme.Accent.primary)

                Text(sentence)
                    .font(.app(size: 13, weight: .regular))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                infoTip
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(AppTheme.Surface.subtle)
            )
        }
    }

    private var infoTip: InfoTip {
        var tip = InfoTip(
            "Every mode can choose its own speech model, language and AI model. When one differs from this line, it is highlighted on that mode."
        )
        tip.iconColor = AppTheme.Text.muted
        tip.iconSize = .small
        return tip
    }

    private var sentence: AttributedString? {
        let hears = shared.transcriptionModel != nil || shared.language != nil
        guard hears || shared.aiModel != nil else { return nil }
        let detectsLanguage = shared.language == ModeListResolver.autoDetectLabel

        var text = plain(shared.isUniversal ? String(localized: "All modes ") : String(localized: "Most modes "))
        if let model = shared.transcriptionModel {
            text += plain(String(localized: "hear with "))
            text += value(model)
            if detectsLanguage {
                text += plain(String(localized: ", detecting the language"))
            } else if let language = shared.language {
                text += plain(String(localized: " in "))
                text += value(language)
            }
        } else if detectsLanguage {
            text += plain(String(localized: "detect the language"))
        } else if let language = shared.language {
            text += plain(String(localized: "hear in "))
            text += value(language)
        }
        if let aiModel = shared.aiModel {
            text += plain(!hears ? String(localized: "write with ") : String(localized: ", and write with "))
            text += value(aiModel)
            if aiModel == mainModel {
                text += plain(String(localized: " (set in AI Models)"))
            }
        }
        text += plain(".")
        if let agentModel, agentModel != shared.aiModel {
            text += plain(String(localized: " The Agent writes with "))
            text += value(agentModel)
            text += plain(".")
        }
        return text
    }

    private func plain(_ string: String) -> AttributedString {
        AttributedString(string)
    }

    private func value(_ string: String) -> AttributedString {
        var run = AttributedString(string)
        run.swiftUI.font = .app(size: 13, weight: .medium)
        run.swiftUI.foregroundColor = AppTheme.Text.primary
        return run
    }
}

/// Quiet marker for the mode used when nothing else matches.
struct DefaultModeIndicator: View {
    var body: some View {
        Text("Default")
            .font(.app(size: 10, weight: .semibold))
            .foregroundStyle(AppTheme.Text.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(AppTheme.Surface.control)
            )
            .help("Default mode is used when no app or website matches")
    }
}

/// One mode: a tile in the mode's spectrum colour, its name, what it does and when it kicks in,
/// plus accent chips for any setting that differs from the shared line.
private struct ModeListRow: View {
    /// Where the name starts, so dividers line up with the text rather than the icon.
    static let textInset: CGFloat = 14 + 34 + 12

    let config: ModeConfig
    let tint: Color
    let facts: ModeListFacts
    let shared: ModeSharedSettings
    let promptTitle: String?
    let modeManager: ModeManager
    let onEdit: () -> Void
    @State private var isHovering = false

    private var purpose: String {
        ModeListPhrasing.purpose(
            outputMode: config.outputMode,
            usesAI: config.isAIEnhancementEnabled,
            promptTitle: promptTitle,
            isAgent: AgentModeGuard.isAgent(config.id)
        )
    }

    /// When the mode runs, plus the full action (prompt name, auto-send) for the tooltip.
    private var trigger: String {
        ModeListPhrasing.trigger(
            isDefault: config.isDefault,
            appNames: config.allAppConfigs.map(\.appName),
            websites: config.allURLConfigs.map(\.url),
            triggerWords: config.triggerWords,
            shortcut: ShortcutStore.shortcut(for: .mode(config.id))
        )
    }

    private var action: String {
        ModeListPhrasing.action(
            outputMode: config.outputMode,
            usesAI: config.isAIEnhancementEnabled,
            promptTitle: promptTitle,
            autoSendKey: config.autoSendKey
        )
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onEdit) {
                HStack(spacing: 12) {
                    ModeIconView(icon: config.icon, size: config.icon.kind == .emoji ? 17 : 14, color: tint)
                        .frame(width: 34, height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(tint.opacity(0.18))
                        )

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(config.name)
                                .font(.app(size: 13, weight: .semibold))
                                .foregroundStyle(AppTheme.Text.primary)
                                .lineLimit(1)
                            if config.isDefault {
                                DefaultModeIndicator()
                            }
                        }
                        Text(purpose)
                            .font(.app(size: 12.5, weight: .regular))
                            .foregroundStyle(AppTheme.Text.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(trigger)
                            .font(.app(size: 11.5, weight: .regular))
                            .foregroundStyle(AppTheme.Text.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(action)
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 8)

                    differences
                }
                .opacity(config.isEnabled ? 1 : 0.5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Edit \(config.name)")

            // The default mode cannot be turned off; the empty slot keeps the chips aligned.
            Group {
                if !config.isDefault {
                    Toggle("Use \(config.name)", isOn: isEnabled)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(AppTheme.Accent.primary)
                        .labelsHidden()
                }
            }
            .frame(width: 36, alignment: .trailing)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 11)
        .background(isHovering ? AppTheme.Surface.subtle : Color.clear)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { config.isEnabled },
            set: { newValue in
                if newValue {
                    modeManager.enableConfiguration(with: config.id)
                } else {
                    modeManager.disableConfiguration(with: config.id)
                }
            }
        )
    }

    @ViewBuilder private var differences: some View {
        HStack(spacing: 6) {
            if facts.transcriptionModel == nil {
                ModeDifferenceChip(
                    systemImage: "exclamationmark.triangle.fill",
                    text: String(localized: "Speech model unavailable"),
                    help: String(localized: "This mode's speech model is missing or not downloaded"),
                    tint: AppTheme.Status.error
                )
            } else if let model = facts.transcriptionModel, model != shared.transcriptionModel {
                ModeDifferenceChip(
                    systemImage: "waveform",
                    text: model,
                    help: String(localized: "Hears with \(model)")
                )
            }

            if facts.language != shared.language {
                let language = facts.language ?? String(localized: "Model's language")
                ModeDifferenceChip(
                    systemImage: "globe",
                    text: language,
                    help: String(localized: "Listens for \(language)")
                )
            }

            if let aiModel = facts.aiModel, aiModel != shared.aiModel {
                ModeDifferenceChip(
                    systemImage: "sparkles",
                    text: aiModel,
                    help: facts.isAgent
                        ? String(localized: "Writes with \(aiModel), the Agent model set in AI Models")
                        : String(localized: "Writes with \(aiModel)")
                )
            }
        }
    }
}

/// A setting that differs from the shared line, tinted so it is the one thing on the row that
/// catches the eye.
private struct ModeDifferenceChip: View {
    let systemImage: String
    let text: String
    let help: String
    var tint: Color = AppTheme.Accent.primary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.app(size: 9, weight: .semibold))
            // Truncated by width rather than by character count, so wide and narrow names get
            // the same room and the ellipsis is the system's.
            MaxWidthLayout(maxWidth: 140) {
                Text(text)
                    .font(.app(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.10)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.35), lineWidth: 0.5))
        .help(help)
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
                .font(.app(size: 13, weight: .regular))
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
