import Foundation

extension ConversationViewModel {
    /// Local ownership is installed before launching independent remote work.
    /// Repeated SwiftUI tasks and connected publisher replay share the same load.
    func load() async {
        guard !Task.isCancelled else { return }
        if activeLiveStoreActivation == nil {
            liveStoreActivationGeneration &+= 1
            activeLiveStoreActivation = liveStoreActivationGeneration
            hasLatchedNewMessagesDividerAnchor = false
            latchedNewMessagesDividerAnchorId = nil
            detailConsumer = agentDetails.retain(agentId: agentId)
            if streamingObserverId == nil { observeStreaming() }
            store.retainConversation(conversationConsumer, agentId: agentId, workspaceId: workspaceId)
            latchEntryWhenReady()
        }
        let activation = liveStoreActivationGeneration
        if loadTask == nil {
            loadTask = Task { [weak self] in
                guard let self, activeLiveStoreActivation == activation, !Task.isCancelled else { return }
                async let model: () = fetchCurrentModel(refresh: false)
                async let hooks: () = hookStore.subscribe(workspaceId: workspaceId, agentId: agentId)
                async let monitors: () = monitoredPrStore.subscribe(workspaceId: workspaceId, agentId: agentId)
                await store.bootstrapTask?.value
                _ = await (model, hooks, monitors)
            }
        }
        await withTaskCancellationHandler {
            await loadTask?.value
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, activeLiveStoreActivation == activation else { return }
                teardownLiveStores()
            }
        }
    }

    /// Rendering can start at the snapshot. Entry positioning waits for the
    /// authoritative marker, so a slow detail read cannot land at a wrong anchor.
    var isEntryScrollReady: Bool { hasLatchedNewMessagesDividerAnchor }

    func latchEntryWhenReady() {
        guard activeLiveStoreActivation != nil, store.metadataReadyForEntry, store.liveTranscript.chatSeeded else { return }
        latchNewMessagesDividerAnchorIfNeeded()
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
        if let streamingObserverId { observedStore.streamingObservers[streamingObserverId] = nil }
        observedStore.entryObservers[conversationConsumer] = { [weak self] in
            guard let self else { return }
            latchEntryWhenReady()
            if store.metadataReadyForEntry, let detail = agentDetails.cached(agentId: agentId) {
                currentModelId = detail.values["model"] as? String
                currentProviderId = (detail.values["provider"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            }
        }
        streamingObserverId = observedStore.observeStreaming { [weak self, weak observedStore] streaming in
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

    func fetchCurrentModel(refresh: Bool = true) async {
        let activation = liveStoreActivationGeneration
        do {
            let (detail, generation) = try await loadCurrentDetail(refresh: refresh)
            guard activation == liveStoreActivationGeneration, !Task.isCancelled else { return }
            modelMetadataGeneration = generation
            currentModelId = detail.values["model"] as? String
            currentProviderId = (detail.values["provider"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let specialistId = detail.metadata["specialist"] as? String {
                await fetchSpecialistInfo(specialistId: specialistId, activation: activation)
            }
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Fetch current model failed: \(error)")
        }
    }

    private func loadCurrentDetail(refresh: Bool) async throws -> (AgentDetail, Int) {
        var generation = optionsStore.loadGeneration
        var epoch = agentDetails.connectionEpoch
        var needsRefresh = refresh
        while true {
            do {
                let detail = try await agentDetails.load(agentId: agentId, workspaceId: workspaceId, refresh: needsRefresh)
                if generation == optionsStore.loadGeneration, epoch == agentDetails.connectionEpoch {
                    return (detail, generation)
                }
            } catch {
                guard !Task.isCancelled,
                      generation != optionsStore.loadGeneration || epoch != agentDetails.connectionEpoch else { throw error }
            }
            // A connection change already invalidated shared detail. A catalog
            // invalidation on the same connection requires explicit revalidation.
            needsRefresh = epoch == agentDetails.connectionEpoch
            generation = optionsStore.loadGeneration
            epoch = agentDetails.connectionEpoch
        }
    }

    private func fetchSpecialistInfo(specialistId: String, activation: Int) async {
        do {
            let result = try await connection.request("specialist.list")
            guard !Task.isCancelled, activation == liveStoreActivationGeneration else { return }
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
