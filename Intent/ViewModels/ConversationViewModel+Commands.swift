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
    var filteredMessageIDs: Set<String> { store.liveTranscript.messageIDs }
    var isStreaming: Bool { store.isStreaming }
    var isLoading: Bool { store.isLoading }
    var showsLoadingState: Bool {
        !agentNotFound && filteredMessages.isEmpty && (isLoading || !store.liveTranscript.chatSeeded)
    }
    var loadingStage: ConversationLiveTranscript.LoadingStage { store.loadingStage }

    func retryNow() async {
        await store.retryNow()
    }

    /// Display-only filter: show only user-authored entries in the
    /// queued-messages section — daemon-originated wakes (hook, PR-monitor,
    /// event-notification) and agent-to-agent sends are hidden. The store
    /// keeps the full queue and flush behavior is unchanged.
    var queuedMessages: [QueuedMessage] {
        store.queuedMessages.filter { $0.isUserMessage }
    }

    /// Synchronously invalidates this screen activation and detaches every
    /// local event handler before captured remote ids are released.
    func teardownLiveStores() {
        optionsStore.releaseCatalogs(consumer: conversationConsumer)
        liveStoreActivationGeneration &+= 1
        activeLiveStoreActivation = nil
        loadTask?.cancel()
        loadTask = nil
        if let detailConsumer { agentDetails.release(agentId: agentId, consumer: detailConsumer) }
        detailConsumer = nil
        if let streamingObserverId { store.streamingObservers[streamingObserverId] = nil }
        streamingObserverId = nil
        store.entryObservers[conversationConsumer] = nil
        store.releaseConversation(conversationConsumer)
        hookStore.deactivate()
        monitoredPrStore.deactivate()
        deactivateScriptMonitors()
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

    // nil distinguishes a cache miss from a loaded empty provider catalog.
    // swiftlint:disable:next discouraged_optional_collection
    var selectableModels: [ModelInfo]? {
        if let providerId = currentProviderId {
            return optionsStore.models(for: providerId)
        }
        return availableModels
    }

    var currentModelDisplayName: String? {
        guard let modelId = currentModelId else { return nil }
        return Self.modelDisplayName(
            modelId: modelId,
            provider: currentProviderId,
            catalog: selectableModels ?? []
        )
    }

    static func modelDisplayName(
        modelId: String,
        provider: String?,
        catalog: [ModelInfo]
    ) -> String {
        catalog.first { model in
            model.id == modelId && (provider == nil || model.provider == provider)
        }?.name ?? modelId
    }

    struct ModelCatalogKey: Equatable {
        let providerId: String?
        let isCached: Bool
        let loadGeneration: Int
    }

    var modelCatalogKey: ModelCatalogKey {
        ModelCatalogKey(
            providerId: currentProviderId,
            isCached: currentProviderId.map { optionsStore.models(for: $0) != nil } ?? false,
            loadGeneration: optionsStore.loadGeneration
        )
    }

    func loadModelCatalogIfNeeded() async {
        let activation = liveStoreActivationGeneration
        let generation = optionsStore.loadGeneration
        if let readUnder = modelMetadataGeneration, readUnder != generation {
            // Reconnect already expires shared detail. A delayed catalog task
            // must reuse that bootstrap even after its reply has settled.
            await fetchCurrentModel(refresh: modelMetadataEpoch == agentDetails.connectionEpoch)
            guard generation == optionsStore.loadGeneration, activation == liveStoreActivationGeneration,
                  !Task.isCancelled else { return }
            guard modelMetadataGeneration == generation else {
                currentModelId = nil
                currentProviderId = nil
                optionsStore.selectModelProvider(nil, consumer: conversationConsumer)
                return
            }
        }
        guard activation == liveStoreActivationGeneration, !Task.isCancelled else { return }
        optionsStore.selectModelProvider(currentProviderId, consumer: conversationConsumer)
        guard let providerId = currentProviderId else { return }
        await loadProviderCatalog(providerId, refresh: false)
    }

    func refreshSelectableModels() async {
        guard !Task.isCancelled else { return }
        if let providerId = currentProviderId {
            optionsStore.selectModelProvider(providerId, consumer: conversationConsumer)
            await loadProviderCatalog(providerId, refresh: true)
        } else {
            await fetchModels()
        }
    }

    private func loadProviderCatalog(_ providerId: String, refresh: Bool) async {
        modelCatalogLoadFailed = false
        let activation = liveStoreActivationGeneration
        let generation = optionsStore.loadGeneration
        if refresh {
            await optionsStore.loadModelsIfNeeded(providerId: providerId, force: true, consumer: conversationConsumer)
        } else {
            await optionsStore.ensureModels(providerId: providerId, consumer: conversationConsumer)
        }
        guard generation == optionsStore.loadGeneration, activation == liveStoreActivationGeneration,
              currentProviderId == providerId, !Task.isCancelled else { return }
        modelCatalogLoadFailed = optionsStore.modelCatalog(for: providerId).loadFailed
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

    func setModel(_ modelId: String) async throws {
        try await store.setModel(agentId: agentId, modelId: modelId, workspaceId: workspaceId)
        currentModelId = modelId
    }

    typealias ImagePlacementError = ConversationAttachmentPipeline.ImagePlacementError
    typealias FilePlacementError = ConversationAttachmentPipeline.FilePlacementError

    static let maxImageReferenceBytes = ConversationAttachmentPipeline.maxImageReferenceBytes

    static func mimeType(for url: URL) -> String? {
        ConversationAttachmentPipeline.mimeType(for: url)
    }
}
