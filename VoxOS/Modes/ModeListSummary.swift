import SwiftUI

/// The settings a mode runs with, resolved to the names the Modes list shows.
struct ModeListFacts: Equatable {
    /// Nil when the mode's transcription model cannot run.
    let transcriptionModel: String?
    /// Nil when the mode leaves the language to the model.
    let language: String?
    /// The model that writes for the mode once the global AI Models choice is applied; nil
    /// when the mode does not use AI.
    let aiModel: String?
    let isAgent: Bool
}

/// What most modes have in common, said once at the top of the list so each row only has to
/// show what makes that mode different.
struct ModeSharedSettings: Equatable {
    var transcriptionModel: String?
    var language: String?
    var aiModel: String?
    /// True when every mode matches all of the above.
    var isUniversal: Bool

    init(transcriptionModel: String? = nil, language: String? = nil, aiModel: String? = nil, isUniversal: Bool) {
        self.transcriptionModel = transcriptionModel
        self.language = language
        self.aiModel = aiModel
        self.isUniversal = isUniversal
    }

    init(facts: [ModeListFacts]) {
        let transcription = Self.mostCommon(facts.map(\.transcriptionModel))
        let language = Self.mostCommon(facts.map(\.language))
        // The Agent can have its own model in AI Models; it should not decide what "everyone" uses.
        let writers = facts.filter { $0.aiModel != nil && !$0.isAgent }
        let aiModel = Self.mostCommon((writers.isEmpty ? facts : writers).map(\.aiModel))
        self.init(
            transcriptionModel: transcription,
            language: language,
            aiModel: aiModel,
            isUniversal: facts.allSatisfy {
                $0.transcriptionModel == transcription && $0.language == language
                    && ($0.aiModel == nil || $0.isAgent || $0.aiModel == aiModel)
            }
        )
    }

    /// The most frequent value; ties go to the one listed first, so the order of modes decides.
    static func mostCommon(_ values: [String?]) -> String? {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for case let value? in values {
            if counts[value] == nil { order.append(value) }
            counts[value, default: 0] += 1
        }
        return order.max { lhs, rhs in
            let lhsCount = counts[lhs] ?? 0
            let rhsCount = counts[rhs] ?? 0
            if lhsCount != rhsCount { return lhsCount < rhsCount }
            // `max` keeps the later of equal elements, so rank earlier entries higher.
            return (order.firstIndex(of: lhs) ?? 0) > (order.firstIndex(of: rhs) ?? 0)
        }
    }
}

/// The plain-language pieces of a Modes list row.
enum ModeListPhrasing {
    static func trigger(
        isDefault: Bool,
        appNames: [String],
        websites: [String],
        triggerWords: [String],
        shortcut: Shortcut?
    ) -> String {
        if isDefault {
            return String(localized: "Used when nothing else matches")
        }

        var clauses: [String] = []
        if let place = place(appNames: appNames, websites: websites) {
            clauses.append(String(localized: "you're in \(place)"))
        }
        if let word = triggerWords.first {
            clauses.append(String(localized: "you say “\(word)”"))
        }
        if let shortcut {
            clauses.append(String(localized: "you press \(shortcut.displayString)"))
        }

        guard !clauses.isEmpty else {
            return String(localized: "Only when you switch to it")
        }
        return String(localized: "When \(clauses.joined(separator: ", or "))")
    }

    static func action(
        outputMode: ModeOutputMode,
        usesAI: Bool,
        promptTitle: String?,
        autoSendKey: AutoSendKey
    ) -> String {
        let prompt = usesAI ? promptTitle : nil
        switch outputMode {
        case .paste:
            var text =
                prompt.map { String(localized: "Writes with the \($0) prompt, then pastes") }
                ?? (usesAI
                    ? String(localized: "Polishes what you say, then pastes")
                    : String(localized: "Pastes what you say"))
            if autoSendKey.isEnabled {
                text += String(localized: " and sends")
            }
            return text
        case .rewrite:
            return prompt.map { String(localized: "Rewrites your selection with the \($0) prompt") }
                ?? String(localized: "Rewrites your selection")
        case .respond:
            return prompt.map { String(localized: "Responds with the \($0) prompt") }
                ?? String(localized: "Responds to what you say")
        case .customCommand:
            return String(localized: "Runs your command")
        }
    }

    /// What the mode is for, in one plain line. Known prompts and output actions get a fixed
    /// description; a custom prompt falls back to its own name.
    static func purpose(
        outputMode: ModeOutputMode,
        usesAI: Bool,
        promptTitle: String?,
        isAgent: Bool
    ) -> String {
        if isAgent {
            return String(localized: "Uses tools and acts on your behalf")
        }
        switch outputMode {
        case .rewrite:
            return String(localized: "Rephrases or changes tone of the selection")
        case .customCommand:
            return String(localized: "Runs your own command on what you say")
        case .respond, .paste:
            break
        }

        let prompt = usesAI ? promptTitle : nil
        switch prompt?.lowercased() {
        case "email"?:
            return String(localized: "Drafts and replies to emails")
        case "chat"?:
            return String(localized: "Writes casual chat messages")
        case "rewrite"?:
            return String(localized: "Rephrases or changes tone of the selection")
        case "assistant"?:
            return String(localized: "Answers questions")
        case "agent"?:
            return String(localized: "Uses tools and acts on your behalf")
        case "default"?, nil:
            if outputMode == .respond {
                return String(localized: "Answers questions")
            }
            return usesAI
                ? String(localized: "Improves wording and structure")
                : String(localized: "Turns speech into text as you talk")
        case _?:
            let title = prompt ?? ""
            return outputMode == .respond
                ? String(localized: "Answers with your “\(title)” prompt")
                : String(localized: "Writes with your “\(title)” prompt")
        }
    }

    private static func place(appNames: [String], websites: [String]) -> String? {
        let apps: String? =
            switch appNames.count {
            case 0: nil
            case 1: appNames[0]
            case 2: String(localized: "\(appNames[0]) or \(appNames[1])")
            default: String(localized: "\(appNames[0]) and \(appNames.count - 1) other apps")
            }
        let sites: String? =
            switch websites.count {
            case 0: nil
            case 1: websites[0]
            default: String(localized: "\(websites.count) websites")
            }

        switch (apps, sites) {
        case (let apps?, let sites?): return String(localized: "\(apps) or \(sites)")
        case (let apps?, nil): return apps
        case (nil, let sites?): return sites
        case (nil, nil): return nil
        }
    }
}

/// Resolves modes against the app's services into `ModeListFacts`.
@MainActor
struct ModeListResolver {
    let enhancementService: AIEnhancementService
    let aiService: AIService
    let transcriptionModelManager: TranscriptionModelManager

    nonisolated static let autoDetectLabel = String(localized: "Auto-detect")

    func facts(for config: ModeConfig) -> ModeListFacts {
        ModeListFacts(
            transcriptionModel: transcriptionModel(for: config),
            language: language(for: config),
            aiModel: aiModel(for: config),
            isAgent: AgentModeGuard.isAgent(config.id)
        )
    }

    func promptTitle(for config: ModeConfig) -> String? {
        if config.selectedAIProvider == AIProvider.voxOSRefine.rawValue {
            return nil
        }
        guard let promptId = config.selectedPrompt, let uuid = UUID(uuidString: promptId) else { return nil }
        return enhancementService.allPrompts.first { $0.id == uuid }?.title
    }

    /// The main model from AI Models when it is set and its provider is connected.
    var mainModel: String? {
        choiceName(AIModelRouting.main)
    }

    /// The Agent's own model from AI Models when it is set and its provider is connected.
    var agentModel: String? {
        choiceName(AIModelRouting.agent)
    }

    private func choiceName(_ choice: AIModelChoice?) -> String? {
        guard let choice, aiService.connectedProviders.contains(choice.provider) else { return nil }
        return choice.model ?? aiService.selectedModel(for: choice.provider)
    }

    private func transcriptionModel(for config: ModeConfig) -> String? {
        switch ModeRuntimeResolver.transcriptionModelResolution(
            mode: config,
            transcriptionModelManager: transcriptionModelManager
        ) {
        case .available(_, let model):
            return model.displayName
        case .noMode, .noSelection, .modelNotFound, .unavailable:
            return nil
        }
    }

    private func language(for config: ModeConfig) -> String? {
        guard let code = config.selectedLanguage else { return nil }
        if code == "auto" { return Self.autoDetectLabel }
        if code == "en" { return String(localized: "English") }

        if let modelName = config.selectedTranscriptionModelName,
            let model = transcriptionModelManager.allAvailableModels.first(where: { $0.name == modelName }),
            let name = TranscriptionLanguageSupport.languages(
                for: model, realtimeEnabled: config.isRealtimeTranscriptionEnabled)[code]
        {
            return name
        }
        return code.uppercased()
    }

    private func aiModel(for config: ModeConfig) -> String? {
        guard config.isAIEnhancementEnabled else { return nil }

        // The runtime resolver applies the global main and Agent models, so the list names the
        // model that will really write, not the one stored on the mode.
        let runtime = ModeRuntimeResolver.currentEnhancementConfiguration(
            mode: config,
            enhancementService: enhancementService,
            aiService: aiService
        )
        switch runtime.provider {
        case .voxOSRefine?:
            return VoxOSRefineService.providerName
        case .localCLI?:
            return AIProvider.localCLI.rawValue
        case _?:
            return runtime.modelName ?? config.selectedAIModel
        case nil:
            return config.selectedAIModel.flatMap { $0.isEmpty ? nil : $0 }
        }
    }
}
