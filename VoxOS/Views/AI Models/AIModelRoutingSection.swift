import SwiftUI

/// AI Models → Main & Fallback Model: one model every mode uses, and one to try when it fails.
/// Both lists offer every connected provider, local ones (Ollama, Local CLI) included.
struct AIModelRoutingSection: View {
    @EnvironmentObject private var aiService: AIService

    @State private var main: AIModelChoice? = AIModelRouting.main
    @State private var fallback: AIModelChoice? = AIModelRouting.fallback
    @State private var agent: AIModelChoice? = AIModelRouting.agent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 2) {
                Text("Main & Fallback Model")
                    .font(.headline)
                InfoTip(
                    "Main: every mode uses this model instead of its own. Leave it on “Each mode's own” to keep choosing per mode in Modes. Agent: the Agent uses this one instead, for example a stronger model than dictation cleanup needs. Fallback: tried when the main model is rate-limited, down, unreachable or answers with nothing. Your text only goes to the models you pick here."
                )
            }

            row(
                title: "Main", noneLabel: "Each mode's own", choice: main,
                set: {
                    main = $0
                    AIModelRouting.main = $0
                })
            row(
                title: "Agent", noneLabel: "Same as Main", choice: agent,
                set: {
                    agent = $0
                    AIModelRouting.agent = $0
                })
            row(
                title: "Fallback", noneLabel: "None", choice: fallback,
                set: {
                    fallback = $0
                    AIModelRouting.fallback = $0
                })

            if eligibleProviders.isEmpty {
                Text("Connect an AI provider below, or start Ollama, to choose a model.")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
            } else if let fallback, !eligibleProviders.contains(fallback.provider) {
                Text("\(fallback.provider.rawValue) is not connected, so the fallback is skipped.")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .onAppear {
            aiService.refreshOllamaAvailabilityInBackground()
            main = AIModelRouting.main
            agent = AIModelRouting.agent
            fallback = AIModelRouting.fallback
        }
    }

    private var eligibleProviders: [AIProvider] {
        aiService.connectedProviders.filter(AIModelRouting.isEligible)
    }

    private func row(
        title: LocalizedStringKey, noneLabel: LocalizedStringKey, choice: AIModelChoice?,
        set: @escaping (AIModelChoice?) -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 70, alignment: .leading)
            Picker(
                "",
                selection: Binding<String>(
                    get: { choice?.provider.rawValue ?? "" },
                    set: { raw in set(AIProvider(rawValue: raw).map { AIModelChoice(provider: $0, model: nil) }) })
            ) {
                Text(noneLabel).tag("")
                ForEach(providerOptions(including: choice?.provider), id: \.rawValue) { provider in
                    Text(provider.rawValue).tag(provider.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            if let choice {
                Picker(
                    "",
                    selection: Binding<String>(
                        get: { choice.model ?? "" },
                        set: { set(AIModelChoice(provider: choice.provider, model: $0.isEmpty ? nil : $0)) })
                ) {
                    Text("Selected model (\(aiService.selectedModel(for: choice.provider)))").tag("")
                    ForEach(modelOptions(for: choice), id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
            Spacer(minLength: 0)
        }
    }

    /// A saved provider that is not connected right now stays listed, so the picker can show it.
    private func providerOptions(including saved: AIProvider?) -> [AIProvider] {
        var options = eligibleProviders
        if let saved, !options.contains(saved) { options.append(saved) }
        return options
    }

    private func modelOptions(for choice: AIModelChoice) -> [String] {
        var models = aiService.availableModels(for: choice.provider)
        if let saved = choice.model, !models.contains(saved) { models.insert(saved, at: 0) }
        return models
    }
}
