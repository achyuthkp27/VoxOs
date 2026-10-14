import SwiftUI

/// AI Models → Your setup: which language model writes for every mode, which one runs the
/// Agent, and which one steps in when the first fails. Three tiles that each open a menu,
/// instead of rows of paired pop-ups; every connected provider is offered, local ones included.
struct AIModelRoutingSection: View {
    @EnvironmentObject private var aiService: AIService

    @State private var main: AIModelChoice? = AIModelRouting.main
    @State private var agent: AIModelChoice? = AIModelRouting.agent
    @State private var fallback: AIModelChoice? = AIModelRouting.fallback

    fileprivate enum Slot: CaseIterable {
        case main, agent, fallback

        var title: LocalizedStringKey {
            switch self {
            case .main: return "Main"
            case .agent: return "Agent"
            case .fallback: return "Fallback"
            }
        }

        var role: LocalizedStringKey {
            switch self {
            case .main: return "Writes for every mode"
            case .agent: return "Runs the Agent"
            case .fallback: return "When the first one fails"
            }
        }

        var noneLabel: LocalizedStringKey {
            switch self {
            case .main: return "Each mode's own"
            case .agent: return "Same as Main"
            case .fallback: return "None"
            }
        }

        var symbol: String {
            switch self {
            case .main: return "text.badge.checkmark"
            case .agent: return "wand.and.stars"
            case .fallback: return "arrow.uturn.backward"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                Text("Your setup")
                    .font(.appMono(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)
                InfoTip(
                    "Main: every mode uses this model instead of its own. Agent: the Agent uses this one instead, for example a stronger model than dictation cleanup needs. Fallback: tried when the model in use is rate-limited, down, unreachable or answers with nothing. Your text only goes to the models you pick here."
                )
            }

            HStack(alignment: .top, spacing: 10) {
                ForEach(Slot.allCases, id: \.self) { slot in
                    tile(slot)
                }
            }

            if eligibleProviders.isEmpty {
                Text("Connect a provider under Cloud, or start Ollama, to choose a model.")
                    .font(.app(size: 12, weight: .regular))
                    .foregroundStyle(AppTheme.Text.secondary)
            }
        }
        .onAppear {
            aiService.refreshOllamaAvailabilityInBackground()
            main = AIModelRouting.main
            agent = AIModelRouting.agent
            fallback = AIModelRouting.fallback
        }
    }

    // MARK: Tiles

    private func choice(_ slot: Slot) -> AIModelChoice? {
        switch slot {
        case .main: return main
        case .agent: return agent
        case .fallback: return fallback
        }
    }

    private func set(_ slot: Slot, _ value: AIModelChoice?) {
        switch slot {
        case .main:
            main = value
            AIModelRouting.main = value
        case .agent:
            agent = value
            AIModelRouting.agent = value
        case .fallback:
            fallback = value
            AIModelRouting.fallback = value
        }
    }

    private func tile(_ slot: Slot) -> some View {
        let current = choice(slot)
        let isConnected = current.map { eligibleProviders.contains($0.provider) } ?? true

        return Menu {
            Button(slot.noneLabel) { set(slot, nil) }
            if !eligibleProviders.isEmpty { Divider() }
            ForEach(eligibleProviders, id: \.rawValue) { provider in
                let models = aiService.availableModels(for: provider)
                if models.isEmpty || provider == .localCLI {
                    Button(provider.rawValue) { set(slot, AIModelChoice(provider: provider, model: nil)) }
                } else {
                    Menu(provider.rawValue) {
                        Button("Provider's default (\(aiService.selectedModel(for: provider)))") {
                            set(slot, AIModelChoice(provider: provider, model: nil))
                        }
                        Divider()
                        ForEach(models, id: \.self) { model in
                            Button(model) { set(slot, AIModelChoice(provider: provider, model: model)) }
                        }
                    }
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: slot.symbol)
                        .font(.app(size: 12, weight: .semibold))
                        .foregroundStyle(current == nil ? AppTheme.Text.secondary : AppTheme.Accent.primary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(current == nil ? AppTheme.Surface.control : AppTheme.Accent.fill))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(slot.title)
                            .font(.app(size: 12, weight: .semibold))
                            .foregroundStyle(AppTheme.Text.primary)
                        Text(slot.role)
                            .font(.app(size: 11, weight: .regular))
                            .foregroundStyle(AppTheme.Text.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.app(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.muted)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(modelLabel(current, slot: slot))
                        .font(.app(size: 15, weight: .semibold))
                        .foregroundStyle(current == nil ? AppTheme.Text.secondary : AppTheme.Text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(providerLabel(current, isConnected: isConnected))
                        .font(.app(size: 11, weight: .medium))
                        .foregroundStyle(isConnected ? AppTheme.Text.secondary : AppTheme.Status.warning)
                        .lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(current == nil ? AppTheme.Surface.card : AppTheme.Surface.tinted)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(current == nil ? AppTheme.Border.card : AppTheme.Selection.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
    }

    private func modelLabel(_ choice: AIModelChoice?, slot: Slot) -> String {
        guard let choice else { return String(localized: slot.noneLabelString) }
        if choice.provider == .localCLI { return String(localized: "Command-line tool") }
        return choice.model ?? aiService.selectedModel(for: choice.provider)
    }

    private func providerLabel(_ choice: AIModelChoice?, isConnected: Bool) -> String {
        guard let choice else { return String(localized: "Not set") }
        return isConnected
            ? choice.provider.rawValue : String(localized: "\(choice.provider.rawValue) · not connected, skipped")
    }

    private var eligibleProviders: [AIProvider] {
        aiService.connectedProviders.filter(AIModelRouting.isEligible)
    }
}

extension AIModelRoutingSection.Slot {
    fileprivate var noneLabelString: String.LocalizationValue {
        switch self {
        case .main: return "Each mode's own"
        case .agent: return "Same as Main"
        case .fallback: return "None"
        }
    }
}
