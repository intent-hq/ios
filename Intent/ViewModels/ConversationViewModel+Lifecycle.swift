import Foundation

extension ConversationViewModel {
    /// The transcript comes only from the `chat.subscribe` seq-0 snapshot;
    /// the load waits for it to apply (or its wait to time out), so the
    /// new-messages divider anchors against the served rows.
    func load() async {
        guard !Task.isCancelled else { return }
        let activation = activateLiveStores()
        await store.subscribeToStreaming(agentId: agentId, workspaceId: workspaceId)
        guard ownsLiveStoreActivation(activation), !Task.isCancelled else { return }

        async let conversation: () = loadTranscript()
        async let queue: () = store.fetchQueue(agentId: agentId)
        async let model: () = fetchCurrentModel()
        async let subscriptions: () = store.fetchSubscriptions(agentId: agentId, workspaceId: workspaceId)
        async let streamingState: () = store.fetchAgentStreamingState(agentId: agentId, raiseOnly: true)
        async let hooks: () = hookStore.subscribe(workspaceId: workspaceId, agentId: agentId)
        async let monitors: () = monitoredPrStore.subscribe(workspaceId: workspaceId, agentId: agentId)

        _ = await (conversation, streamingState)
        guard ownsLiveStoreActivation(activation), !Task.isCancelled else { return }
        latchNewMessagesDividerAnchorIfNeeded()
        _ = await (queue, model, subscriptions, hooks, monitors)
    }

    private func activateLiveStores() -> Int {
        liveStoreActivationGeneration &+= 1
        activeLiveStoreActivation = liveStoreActivationGeneration
        return liveStoreActivationGeneration
    }

    private func ownsLiveStoreActivation(_ activation: Int) -> Bool {
        activeLiveStoreActivation == activation
    }

    private func loadTranscript() async {
        await store.subscribeLiveChat(agentId: agentId, workspaceId: workspaceId)
        await store.awaitLiveChatSnapshot()
    }

    func latchNewMessagesDividerAnchorIfNeeded() {
        guard !hasLatchedNewMessagesDividerAnchor else { return }
        hasLatchedNewMessagesDividerAnchor = true
        latchedNewMessagesDividerAnchorId = NewMessagesDivider.resolveAnchor(
            messageIds: store.messages.map(\.id),
            lastSeenMessageId: store.lastSeenMessageId
        )
    }

    // MARK: - Seen-marker lifecycle

    func observeStreaming() {
        let observedStore = store
        previousIsStreaming = observedStore.isStreaming
        observedStore.onStreamingChanged = { [weak self, weak observedStore] streaming in
            guard let self, let observedStore, store === observedStore else { return }
            let wasStreaming = previousIsStreaming
            previousIsStreaming = streaming
            if wasStreaming, !streaming {
                turnFinished()
            }
        }
    }

    private func turnFinished() {
        guard isOnScreen, isAppActive else { return }
        scheduleDebouncedMarkSeen()
    }

    func conversationAppeared() {
        isOnScreen = true
    }

    func conversationDisappeared() {
        isOnScreen = false
        teardownLiveStores()
        fireMarkSeenNow()
    }

    func scenePhaseChanged(isActive: Bool) {
        let wasActive = isAppActive
        isAppActive = isActive
        guard wasActive, !isActive else { return }
        if isOnScreen {
            fireMarkSeenNow()
        } else {
            markSeenDebounceTask?.cancel()
            markSeenDebounceTask = nil
        }
    }

    func scheduleDebouncedMarkSeen() {
        markSeenDebounceTask?.cancel()
        markSeenDebounceTask = Task { [weak self] in
            guard let duration = self?.markSeenDebounceDuration else { return }
            try? await Task.sleep(for: duration)
            guard let self, !Task.isCancelled else { return }
            markSeenDebounceTask = nil
            await store.markSeen(agentId: agentId, workspaceId: workspaceId)
        }
    }

    private func fireMarkSeenNow() {
        markSeenDebounceTask?.cancel()
        markSeenDebounceTask = nil
        let store = self.store
        let agentId = self.agentId
        let workspaceId = self.workspaceId
        Task { await store.markSeen(agentId: agentId, workspaceId: workspaceId) }
    }

    // MARK: - Agent metadata

    func stopAgent(agentId: String) async {
        do {
            _ = try await connection.request(
                "agent.stop",
                params: ["agentId": agentId]
            )
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Failed to stop agent: \(error)")
        }
    }

    func fetchCurrentModel() async {
        do {
            var generation = optionsStore.loadGeneration
            var result = try await connection.request(
                "agent.get",
                params: ["agentId": agentId]
            )
            while generation != optionsStore.loadGeneration {
                generation = optionsStore.loadGeneration
                result = try await connection.request(
                    "agent.get",
                    params: ["agentId": agentId]
                )
            }
            modelMetadataGeneration = generation
            if let dict = result as? [String: Any],
               let agent = dict["agent"] as? [String: Any] {
                if let model = agent["model"] as? String {
                    currentModelId = model
                }
                if let provider = agent["provider"] as? String, !provider.isEmpty {
                    currentProviderId = provider
                }
                if let metadata = agent["metadata"] as? [String: Any],
                   let specialistId = metadata["specialist"] as? String {
                    await fetchSpecialistInfo(specialistId: specialistId)
                }
            }
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Fetch current model failed: \(error)")
        }
    }

    private func fetchSpecialistInfo(specialistId: String) async {
        do {
            let result = try await connection.request("specialist.list")
            if let dict = result as? [String: Any],
               let items = dict["specialists"] as? [[String: Any]],
               let match = items.first(where: { ($0["id"] as? String) == specialistId }) {
                specialistName = match["name"] as? String
                specialistDescription = match["description"] as? String
            }
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Fetch specialist info failed: \(error)")
        }
    }
}
