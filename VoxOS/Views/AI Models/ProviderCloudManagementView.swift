import AppKit
import SwiftUI

struct CloudProviderManagementView: View {
    let selectedProviderID: String?
    let onSelectProvider: (ProviderDescriptor) -> Void

    private var providerDescriptors: [ProviderDescriptor] {
        let enhancementProviders: [AIProvider] = [
            .openAI,
            .openRouter,
            .anthropic,
            .gemini,
            .groq,
            .mistral,
            .cerebras,
        ]

        var descriptors = enhancementProviders.map { aiProvider in
            ProviderDescriptor(
                displayName: aiProvider.rawValue,
                providerKey: aiProvider.rawValue,
                aiProvider: aiProvider,
                cloudProvider: matchingCloudProvider(for: aiProvider)
            )
        }

        for cloudProvider in CloudProviderRegistry.allProviders {
            let alreadyIncluded = descriptors.contains {
                $0.providerKey.caseInsensitiveCompare(cloudProvider.providerKey) == .orderedSame
            }
            guard !alreadyIncluded else { continue }

            descriptors.append(
                ProviderDescriptor(
                    displayName: cloudProvider.providerKey,
                    providerKey: cloudProvider.providerKey,
                    aiProvider: nil,
                    cloudProvider: cloudProvider
                )
            )
        }

        let preferredOrder = [
            "Groq", "Cerebras", "Gemini", "OpenAI", "OpenRouter", "Anthropic", "Mistral",
            "Deepgram", "ElevenLabs", "Soniox", "Speechmatics", "AssemblyAI", "xAI", "Cartesia",
        ]

        return descriptors.sorted { first, second in
            let firstIndex = preferredOrder.firstIndex(of: first.displayName) ?? Int.max
            let secondIndex = preferredOrder.firstIndex(of: second.displayName) ?? Int.max
            if firstIndex != secondIndex { return firstIndex < secondIndex }
            return first.displayName < second.displayName
        }
    }

    var body: some View {
        let descriptors = providerDescriptors

        return VStack(alignment: .leading, spacing: 10) {
            ProviderSectionHeader(
                title: "Cloud providers",
                subtitle: "Connect providers here, then choose models inside Modes."
            )
            .padding(.horizontal, 4)

            ModelListGroup {
                ForEach(Array(descriptors.enumerated()), id: \.element.id) { index, descriptor in
                    if index > 0 {
                        ModelListDivider()
                    }
                    ProviderListRow(
                        descriptor: descriptor,
                        isSelected: selectedProviderID == descriptor.id,
                        onSelect: {
                            onSelectProvider(descriptor)
                        }
                    )
                }
            }
        }
    }

    private func matchingCloudProvider(for aiProvider: AIProvider) -> (any CloudProvider)? {
        CloudProviderRegistry.allProviders.first {
            $0.providerKey.caseInsensitiveCompare(aiProvider.rawValue) == .orderedSame
        }
    }
}

struct ProviderDescriptor: Identifiable {
    let displayName: String
    let providerKey: String
    let aiProvider: AIProvider?
    let cloudProvider: (any CloudProvider)?

    var id: String { providerKey }

    var transcriptionModels: [CloudModel] {
        cloudProvider?.models ?? []
    }

    var hasTranscription: Bool {
        !transcriptionModels.isEmpty
    }

    var hasEnhancement: Bool {
        aiProvider != nil
    }

    var brandAssetName: String? {
        switch providerKey.lowercased() {
        case "openai":
            return "provider-openai"
        case "openrouter":
            return "provider-openrouter"
        case "anthropic":
            return "provider-anthropic"
        case "gemini":
            return "provider-gemini"
        case "groq":
            return "provider-groq"
        case "mistral":
            return "provider-mistral"
        case "cerebras":
            return "provider-cerebras"
        case "deepgram":
            return "provider-deepgram"
        case "elevenlabs":
            return "provider-elevenlabs"
        case "soniox":
            return "provider-soniox"
        case "speechmatics":
            return "provider-speechmatics"
        case "assemblyai":
            return "provider-assemblyai"
        case "xai":
            return "provider-xai"
        case "cartesia":
            return "provider-cartesia"
        default:
            return nil
        }
    }

    var apiConsoleURL: URL? {
        switch providerKey.lowercased() {
        case "groq":
            return URL(string: "https://console.groq.com/keys")
        case "cerebras":
            return URL(string: "https://cloud.cerebras.ai/platform")
        case "gemini":
            return URL(string: "https://aistudio.google.com/app/apikey")
        case "openai":
            return URL(string: "https://platform.openai.com/api-keys")
        case "openrouter":
            return URL(string: "https://openrouter.ai/keys")
        case "anthropic":
            return URL(string: "https://console.anthropic.com/settings/keys")
        case "mistral":
            return URL(string: "https://console.mistral.ai/api-keys/")
        case "deepgram":
            return URL(string: "https://console.deepgram.com/project/keys")
        case "elevenlabs":
            return URL(string: "https://elevenlabs.io/app/settings/api-keys")
        case "soniox":
            return URL(string: "https://console.soniox.com/api-keys")
        case "speechmatics":
            return URL(string: "https://console.speechmatics.com/")
        case "assemblyai":
            return URL(string: "https://www.assemblyai.com/dashboard/signup")
        case "xai":
            return URL(string: "https://console.x.ai/")
        case "cartesia":
            return URL(string: "https://play.cartesia.ai/keys")
        default:
            return nil
        }
    }
}

private struct ProviderListRow: View {
    @EnvironmentObject private var aiService: AIService

    let descriptor: ProviderDescriptor
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovering = false

    private var isConfigured: Bool {
        APIKeyManager.shared.hasAPIKey(forProvider: descriptor.providerKey)
    }

    private var statusText: LocalizedStringKey {
        isConfigured ? "Connected" : "Not connected"
    }

    private var statusColor: Color {
        isConfigured ? AppTheme.Status.positive : .secondary
    }

    private var iconName: String {
        if descriptor.hasTranscription && descriptor.hasEnhancement { return "rectangle.2.swap" }
        if descriptor.hasTranscription { return "captions.bubble.fill" }
        return "sparkles"
    }

    private var capabilitySummary: String {
        var parts: [String] = []

        let transcriptionCount = descriptor.transcriptionModels.count
        if transcriptionCount > 0 {
            parts.append(transcriptionModelCountText(transcriptionCount))
        }

        if let provider = descriptor.aiProvider {
            let enhancementCount = aiService.availableModels(for: provider).count
            parts.append(enhancementModelCountText(enhancementCount))
        }

        return parts.joined(separator: " · ")
    }

    private func transcriptionModelCountText(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 transcription model")
            : String(localized: "\(count) transcription models")
    }

    private func enhancementModelCountText(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 language model")
            : String(localized: "\(count) language models")
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: ModelRowMetrics.spacing) {
                ProviderBrandIcon(
                    descriptor: descriptor,
                    fallbackSystemImage: iconName,
                    isSelected: isSelected,
                    size: ModelRowMetrics.iconSize,
                    iconSize: 15
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(descriptor.displayName)
                        .font(.app(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.primary)

                    Text(capabilitySummary)
                        .font(.app(size: 11.5, weight: .medium))
                        .foregroundStyle(AppTheme.Text.secondary)
                        .lineLimit(1)
                }

                Spacer()

                ProviderStatusBadge(title: statusText, color: statusColor)

                Image(systemName: "chevron.right")
                    .font(.app(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.muted)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, ModelRowMetrics.horizontalPadding)
            .padding(.vertical, 12)
            .background(
                isSelected ? AppTheme.Selection.fill : (isHovering ? AppTheme.Surface.subtle : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }
}
