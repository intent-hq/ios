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
        guard !streamingEventsActive || self.agentId != agentId else { return }
        // Agent ids are backend-wide. A second window's route hint cannot
        // replace a live channel; only shared agent detail supplies authority.
        bootstrapWorkspaceHint = workspaceId
        let knownWorkspace = commands.agentDetails.cached(agentId: agentId)?.values["workspaceId"] as? String
        bindStreaming(agentId: agentId, workspaceId: knownWorkspace)
        startBootstrap()
    }

    func resolveWorkspaceFromDetail() {
        guard let agentId, let detail = commands.agentDetails.cached(agentId: agentId),
              let workspace = detail.values["workspaceId"] as? String, !workspace.isEmpty else {
            if let agentId { commands.agentDetails.invalidate(agentId: agentId) }
            failWorkspaceAuthority()
            return
        }
        let requestedWorkspace = workspaceId ?? bootstrapWorkspaceHint
        workspaceId = workspace
        liveTranscript.workspaceId = workspace
        if streamingEventsActive, requestedWorkspace != workspace || subscriptionsNeedAuthorityRecovery { invalidateSubscriptions() }
        subscriptionsNeedAuthorityRecovery = false
        workspaceAuthorityFailed = false
        let events = pendingWorkspaceEvents
        pendingWorkspaceEvents.removeAll()
        isFoldingWorkspaceEvents = true
        // A successful shared read supersedes only fields it supplied, and only
        // events preceding its actual RPC start. Local confirmations also win.
        let confirmed = commands.confirmedMarkerRevisions
        for pending in events {
            let changed = Set(confirmed.keys.filter { confirmed[$0] != pending.confirmedMarkerRevisions[$0] })
                .union(detail.markerReadSequences.keys.filter { pending.receivedAt < detail.markerReadSequences[$0, default: 0] })
            handleStreamEvent("event", params: pending.event, ignoringMarkers: changed, receivedAt: pending.receivedAt)
        }
        commands.queueMutations.finish()
        isFoldingWorkspaceEvents = false
        finishWorkspaceAuthorityWaiters(ready: true)
    }

    func awaitWorkspaceAuthority() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard workspaceId == nil, bootstrapWorkspaceHint != nil else { return true }
        guard streamingEventsActive, connectionManager.connectionState == .connected else { return false }
        guard !workspaceAuthorityFailed else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { workspaceAuthorityWaiters[id] = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.workspaceAuthorityWaiters.removeValue(forKey: id)?.resume(returning: false)
            }
        }
    }

    func failWorkspaceAuthority() {
        guard workspaceId == nil, bootstrapWorkspaceHint != nil else { return }
        workspaceAuthorityFailed = true
        subscriptionsNeedAuthorityRecovery = true
        finishWorkspaceAuthorityWaiters(ready: false)
    }

    private func finishWorkspaceAuthorityWaiters(ready: Bool) {
        let waiters = workspaceAuthorityWaiters.values
        workspaceAuthorityWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: ready) }
    }

    func releaseConversation(_ consumer: UUID) {
        guard consumers.remove(consumer) != nil, consumers.isEmpty else { return }
        deactivateStreaming()
    }

    /// Idempotent for this activation/connection, even after all reads settle.
    func startBootstrap(reconnecting: Bool = false) {
        guard bootstrapTask == nil, streamingEventsActive, let agentId,
              let workspace = workspaceId ?? bootstrapWorkspaceHint else { return }
        let generation = bootstrapGeneration
        bootstrapTask = Task { [weak self] in
            guard let self, generation == bootstrapGeneration, !Task.isCancelled else { return }
            async let transcript: () = loadInitialTranscript(agentId: agentId)
            async let metadata: () = fetchAgentStreamingState(agentId: agentId, raiseOnly: !reconnecting, refresh: false)
            async let queue: () = fetchQueue(agentId: agentId)
            async let subscriptions: () = fetchSubscriptions(agentId: agentId, workspaceId: workspace)
            _ = await (transcript, metadata, queue, subscriptions)
        }
    }

    private func loadInitialTranscript(agentId: String) async {
        guard !Task.isCancelled else { return }
        await subscribeLiveChat(agentId: agentId, workspaceId: workspaceId)
        guard !Task.isCancelled else { return }
        await awaitLiveChatSnapshot()
    }

    func cancelBootstrap() {
        bootstrapGeneration &+= 1
        commands.queueMutations.cancel()
        finishWorkspaceAuthorityWaiters(ready: false)
        workspaceAuthorityFailed = false
        subscriptionsNeedAuthorityRecovery = false
        pendingWorkspaceEvents.removeAll()
        metadataReadyForEntry = false
        bootstrapTask?.cancel()
        bootstrapTask = nil
        queueReads.cancel()
        commands.invalidateQueueReads()
        subscriptionReads.cancel()
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
        guard !isFoldingWorkspaceEvents else { return }
        for observer in Array(entryObservers.values) { observer() }
    }
}
