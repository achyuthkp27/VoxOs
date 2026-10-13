import Foundation

@MainActor
extension VoxOSEngine {
    func sendAssistantFollowUp(_ text: String, transcription: Transcription? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
            let assistantChat,
            let provider = assistantSession.provider
        else {
            logger.error(
                "sendAssistantFollowUp bailed: trimmedEmpty=\(trimmed.isEmpty) hasChat=\(self.assistantChat != nil) provider=\(String(describing: self.assistantSession.provider), privacy: .public) phase=\(String(describing: self.assistantSession.phase), privacy: .public)"
            )
            return
        }

        let modelName = assistantSession.modelName
        let modeName = assistantSession.modeName
        let modeEmoji = assistantSession.modeEmoji
        let promptName = assistantSession.promptName
        // The stored prompt was built for the first request; a follow-up that first mentions music
        // or notes needs those tools described too.
        let systemPrompt = [assistantSession.systemPrompt, AgentToolCatalog.onDemandSection(for: trimmed)]
            .compactMap { $0 }.joined(separator: "\n\n")
        let userMessage = assistantSession.beginFollowUp(trimmed)

        // "yes" to "Did you mean Slack?" has no meaning to a model that never saw the offer, and
        // it answers with a made-up how-to. The offer is remembered locally, so answer it here.
        // "open Chrome" typed as a follow-up must open Chrome, not be narrated by the model.
        if let quick = await AgentQuickIntents.handle(trimmed) {
            guard assistantSession.hasMessage(id: userMessage.id) else { return }
            assistantSession.finishFollowUp(quick)
            scheduleAutoCloseIfOnlyLaunched()
            return
        }

        AgentAutoClose.beginRun()
        let offered = AgentQuickIntents.takePendingSuggestions()
        if let local = AgentQuickIntents.followUp(reply: trimmed, suggestions: offered) {
            let text = await AgentQuickIntents.perform(local)
            guard assistantSession.hasMessage(id: userMessage.id) else { return }
            assistantSession.finishFollowUp(text)
            scheduleAutoCloseIfOnlyLaunched()
            return
        }

        do {
            let reply = try await assistantChat.requestAssistantReply(
                provider: provider,
                modelName: modelName,
                systemPrompt: systemPrompt,
                messages: assistantSession.messages
            )

            guard assistantSession.hasMessage(id: userMessage.id),
                assistantSession.provider == provider
            else {
                return
            }

            assistantSession.finishFollowUp(reply.text)

            do {
                if let transcription {
                    assistantChat.applyAssistantTurn(
                        transcription: transcription,
                        response: reply,
                        provider: provider,
                        modelName: modelName,
                        promptName: promptName
                    )
                } else {
                    try assistantChat.saveTypedAssistantTurn(
                        input: trimmed,
                        response: reply,
                        provider: provider,
                        modelName: modelName,
                        promptName: promptName,
                        modeName: modeName,
                        modeEmoji: modeEmoji
                    )
                }
            } catch {
                let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                NotificationManager.shared.showNotification(
                    title: String(
                        format: String(localized: "Assistant response was not saved: %@"),
                        String(errorDescription.prefix(80))),
                    type: .warning
                )
            }
        } catch {
            guard assistantSession.hasMessage(id: userMessage.id),
                assistantSession.provider == provider
            else {
                return
            }
            let errorDescription = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            assistantSession.fail(errorDescription)
        }
    }

    func completeAssistantResponse(
        _ response: String,
        systemPrompt: String?
    ) async {
        assistantSession.finishInitialResponse(response, systemPrompt: systemPrompt)
        scheduleAutoCloseIfOnlyLaunched()
    }

    /// A request that only opened something has nothing to follow up on, so the reply panel goes
    /// away by itself instead of sitting on "Opened Slack." as if the Agent had hung. Everything
    /// is re-checked when the delay is up: if the user has started talking again or the reply was
    /// replaced, the panel is theirs and stays.
    private func scheduleAutoCloseIfOnlyLaunched() {
        let armed = AgentAutoClose.consume()
        guard armed, AgentAutoClose.isEnabled, let replyID = assistantSession.messages.last?.id else { return }

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(AgentAutoClose.delay * 1_000_000_000))
            guard let self else { return }
            let idle: Bool
            if case .idle = self.recordingState { idle = true } else { idle = false }
            let unchanged = self.assistantSession.messages.last?.id == replyID
            guard
                AgentAutoClose.shouldDismiss(
                    armed: armed, settingEnabled: AgentAutoClose.isEnabled, recorderIdle: idle,
                    sessionUnchanged: unchanged)
            else { return }
            await self.recorderUIManager?.dismissRecorderPanel()
        }
    }
}
