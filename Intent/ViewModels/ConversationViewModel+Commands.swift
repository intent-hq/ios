import Foundation

extension ConversationViewModel {
    var messages: [ConversationMessage] { store.messages }

    /// All transcript messages — nothing is display-filtered anymore.
    /// Event-notification wakes render as a compact event-wake banner and
    /// agent-to-agent sends (`metadata.type == "agent_message"`) render with
    /// a sender attribution header (FE parity: ChatPanel.svelte /
    /// ChatMessage.svelte), so MessageView owns all automated-row rendering.
    var filteredMessages: [ConversationMessage] {
        store.messages
    }
    var isStreaming: Bool { store.isStreaming }
    var isLoading: Bool { store.isLoading }
    /// Display-only filter: show only user-authored entries in the
    /// queued-messages section — daemon-originated wakes (hook, PR-monitor,
    /// event-notification) and agent-to-agent sends are hidden. The store
    /// keeps the full queue and flush behavior is unchanged.
    var queuedMessages: [QueuedMessage] {
        store.queuedMessages.filter { $0.isUserMessage }
    }

    /// Tears down the live-store subscriptions (background hooks + PR
    /// monitors) when the conversation leaves the screen (`load()`
    /// re-subscribes on the next appearance).
    func teardownLiveStores() async {
        await hookStore.unsubscribe()
        await monitoredPrStore.unsubscribe()
    }

    func cancelWait() async {
        await store.cancelSubscriptions(agentId: agentId, workspaceId: workspaceId)
    }

    func stopAllWatchedAgents() async {
        let ids = store.watchedAgentIds
        await store.stopWatchedAgents(
            agentIds: ids,
            parentAgentId: agentId,
            workspaceId: workspaceId
        )
    }

    /// Send a suggested prompt as-is: prompt text only. Unlike `sendMessage`,
    /// this never attaches `pendingImages` and never clears the persisted
    /// composer draft — the in-progress draft (text + attachments) stays
    /// intact for the user's own message.
    func sendSuggestedPrompt(_ prompt: String) async {
        do {
            try await store.sendMessage(agentId: agentId, content: prompt, workspaceId: workspaceId)
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Send suggested prompt failed: \(error)")
        }
    }

    func stopStreaming() async {
        await store.stopStreaming(agentId: agentId)
    }

    // MARK: - Queue management

    func editQueuedMessage(messageId: String, content: String) async {
        do {
            try await store.editQueuedMessage(agentId: agentId, messageId: messageId, content: content)
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Edit queued message failed: \(error)")
        }
    }

    func removeQueuedMessage(messageId: String) async {
        do {
            try await store.removeQueuedMessage(agentId: agentId, messageId: messageId)
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Remove queued message failed: \(error)")
        }
    }

    func sendQueuedMessageNow(messageId: String) async {
        do {
            try await store.sendQueuedMessageNow(agentId: agentId, messageId: messageId, workspaceId: workspaceId)
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Send now failed: \(error)")
        }
    }

    func fetchModels() async {
        do {
            // Backend returns flat: [{ id: "sonnet4.5", name: "sonnet4.5 (balanced)", provider: "auggie" }]
            let raw = try await store.getModels(agentId: agentId)
            availableModels = raw.compactMap { dict -> ModelInfo? in
                guard let id = dict["id"] as? String,
                      let name = dict["name"] as? String else { return nil }
                let provider = dict["provider"] as? String ?? "Unknown"
                return ModelInfo(id: id, name: name, provider: provider)
            }
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Fetch models failed: \(error)")
        }
    }

    func setModel(_ modelId: String) async {
        do {
            try await store.setModel(agentId: agentId, modelId: modelId, workspaceId: workspaceId)
            currentModelId = modelId
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Set model failed: \(error)")
        }
    }

    typealias ImagePlacementError = ConversationAttachmentPipeline.ImagePlacementError
    typealias FilePlacementError = ConversationAttachmentPipeline.FilePlacementError

    static let maxImageReferenceBytes = ConversationAttachmentPipeline.maxImageReferenceBytes

    static func mimeType(for url: URL) -> String? {
        ConversationAttachmentPipeline.mimeType(for: url)
    }
}
