import Combine
import Foundation

extension ConversationStore {
    func observeConnection() {
        connectionObserver = connectionManager.connectionStatePublisher.sink { [weak self] state in
            guard let self, state != observedConnectionState else { return }
            observedConnectionState = state
            guard streamingEventsActive else { return }
            cancelBootstrap()
            cancelMetadataRefreshes()
            liveTranscript.prepareForReconnect()
            if state == .connected { startBootstrap(reconnecting: true) }
        }
        feedObserver = connectionManager.globalSubscriptionPublisher.sink { [weak self] state in
            guard let self, streamingEventsActive else { return }
            if state != .subscribed {
                needsFeedReconciliation = true
                metadataReadyForEntry = false
            } else if needsFeedReconciliation {
                needsFeedReconciliation = false
                guard let agentId else { return }
                // The initial reads may precede the global ACK. Close that gap
                // exactly once when the feed becomes ready, including retry.
                commands.agentDetails.invalidate(agentId: agentId)
                scheduleMetadataRefresh()
                refreshQueue()
                invalidateSubscriptions()
            }
        }
    }

    func retainConversation(_ consumer: UUID, agentId: String, workspaceId: String) {
        consumers.insert(consumer)
        bindStreaming(agentId: agentId, workspaceId: workspaceId)
        startBootstrap()
    }

    func releaseConversation(_ consumer: UUID) {
        guard consumers.remove(consumer) != nil, consumers.isEmpty else { return }
        deactivateStreaming()
    }

    /// Idempotent for this activation/connection, even after all reads settle.
    func startBootstrap(reconnecting: Bool = false) {
        guard bootstrapTask == nil, streamingEventsActive, let agentId, let workspaceId else { return }
        let generation = bootstrapGeneration
        bootstrapTask = Task { [weak self] in
            guard let self, generation == bootstrapGeneration, !Task.isCancelled else { return }
            async let transcript: () = loadInitialTranscript(agentId: agentId, workspaceId: workspaceId)
            async let metadata: () = fetchAgentStreamingState(agentId: agentId, raiseOnly: !reconnecting, refresh: false)
            async let queue: () = fetchQueue(agentId: agentId)
            async let subscriptions: () = fetchSubscriptions(agentId: agentId, workspaceId: workspaceId)
            _ = await (transcript, metadata, queue, subscriptions)
        }
    }

    private func loadInitialTranscript(agentId: String, workspaceId: String) async {
        guard !Task.isCancelled else { return }
        await subscribeLiveChat(agentId: agentId, workspaceId: workspaceId)
        guard !Task.isCancelled else { return }
        await awaitLiveChatSnapshot()
    }

    func cancelBootstrap() {
        bootstrapGeneration &+= 1
        metadataReadyForEntry = false
        bootstrapTask?.cancel()
        bootstrapTask = nil
        queueReadTask?.cancel()
        queueReadTask = nil
        queueReadPending = false
        commands.invalidateQueueReads()
        subscriptionReadTask?.cancel()
        subscriptionReadTask = nil
        subscriptionRevision &+= 1
        watchedAgentCoordinator.invalidateReads()
    }

    /// Explicit recovery entry point used by connection tests and callers.
    /// Publisher replay never invokes it; only actual transitions bootstrap.
    func onReconnected() async {
        guard streamingEventsActive else { return }
        cancelBootstrap()
        cancelMetadataRefreshes()
        liveTranscript.prepareForReconnect()
        startBootstrap(reconnecting: true)
        await bootstrapTask?.value
    }

    @discardableResult
    func observeStreaming(_ observer: @escaping (Bool) -> Void) -> UUID {
        let id = UUID()
        streamingObservers[id] = observer
        return id
    }

    func notifyStreamingChanged() {
        for observer in Array(streamingObservers.values) { observer(isStreaming) }
    }

    func notifyEntryStateChanged() {
        for observer in Array(entryObservers.values) { observer() }
    }
}
