import Foundation

extension ConversationLiveTranscript {
    /// Registers the sole transcript source: `chat.subscribe`, whose seq-0
    /// snapshot replaces the transcript and whose deltas keep it current.
    /// Returns once the registration is acked (its snapshot is then awaited
    /// through `awaitSnapshot`, bounded by `snapshotTimeout`) or rejected (a
    /// backoff retry is then scheduled). A registration opened over an empty
    /// transcript raises `isLoading` until its snapshot lands.
    func subscribe(agentId: String, workspaceId: String? = nil) async {
        bind(agentId: agentId, workspaceId: workspaceId)
        // An explicit registration supersedes any pending self-heal.
        cancelSnapshotRecovery()
        chatChannelActive = true
        chatSeeded = false
        if messages.isEmpty {
            isLoading = true
        }
        let generation = bindingGeneration

        // A reply (or failure) that lands after a rebind to another agent must
        // leave the new binding's channel state untouched, so the error is
        // carried as a value and only inspected on the still-bound path.
        let outcome: Result<String?, Error>? = await whileBound {
            do {
                let result = try await connectionManager.request("chat.subscribe", params: [
                    "agentId": agentId,
                    "replaceGroup": "ios-chat-\(agentId)",
                    "projection": "slim"
                ])
                return .success((result as? [String: Any])?["subscriptionId"] as? String)
            } catch {
                return .failure(error)
            }
        } onStale: { outcome in
            if case .success(let orphanedId?) = outcome {
                await releaseOrphanedSubscription(orphanedId)
            }
        }
        guard let outcome else { return }
        applySubscribeOutcome(outcome, generation: generation)
    }

    /// Registers the acked subscription's handler and arms the seq-0 snapshot
    /// timeout, or clears the channel and schedules a backoff retry when the
    /// registration was rejected.
    private func applySubscribeOutcome(_ outcome: Result<String?, Error>, generation: Int) {
        switch outcome {
        case .success(let subscriptionId?):
            if let previous = chatSubscriptionId, previous != subscriptionId {
                connectionManager.unregisterSubscriptionHandler(id: previous)
            }
            chatSubscriptionId = subscriptionId
            connectionManager.registerSubscriptionHandler(id: subscriptionId) { [weak self] push in
                self?.handlePush(push)
            }
            AppLog.conversation.info(
                "[ConversationStore] Subscribed to chat.subscribe: \(subscriptionId)"
            )
            // A snapshot that raced the ack has already seeded the channel.
            guard !chatSeeded else { return }
            armSnapshotTimeout(generation: generation)
        case .success(nil):
            clearChannel()
            AppLog.conversation.warning(
                "[ConversationStore] chat.subscribe returned no subscriptionId, retrying with backoff"
            )
            scheduleRetry(generation: generation)
        case .failure(let error):
            clearChannel()
            AppLog.conversation.warning(
                "[ConversationStore] chat.subscribe failed: \(error), retrying with backoff"
            )
            onSubscribeError?(error)
            scheduleRetry(generation: generation)
        }
    }

    /// Gap / rejected-empty-snapshot recovery: a fresh registration whose
    /// seq-0 snapshot replaces the transcript. There is no page fetch to fall
    /// back on; a registration that fails or stays silent self-heals on the
    /// retry schedule inside `subscribe`.
    func resnapshot() async {
        resnapshotInProgress = true
        defer { resnapshotInProgress = false }
        chatLive = false
        chatSeeded = false

        await releaseCurrentSubscription()

        if let agentId {
            await subscribe(agentId: agentId, workspaceId: workspaceId)
        }
    }

    func prepareForReconnect() {
        chatLive = false
        if let subscriptionId = chatSubscriptionId {
            connectionManager.unregisterSubscriptionHandler(id: subscriptionId)
        }
        chatSubscriptionId = nil
        chatChannelActive = false
        chatSeeded = false
        resnapshotInProgress = false
        emptySnapshotRecoveryAttempts = 0
        // The reconnect registration is the recovery: drop any pending retry
        // and start the backoff over.
        resetBackoff()
        resumeSnapshotWaiters()
    }

    // MARK: - Snapshot wait, timeout and backoff retry

    /// Parks until the pending registration's seq-0 snapshot applies, its
    /// wait times out, or the channel is torn down (rejection, rebind, reset,
    /// reconnect). Returns at once when no registration is awaiting one.
    func awaitSnapshot() async {
        guard chatChannelActive, !chatSeeded else { return }
        let id = UUID()
        await withCheckedContinuation { continuation in
            snapshotWaiters[id] = continuation
        }
    }

    func resumeSnapshotWaiters() {
        let waiters = snapshotWaiters
        snapshotWaiters = [:]
        for waiter in waiters.values {
            waiter.resume()
        }
    }

    /// The registration acked but its seq-0 snapshot never came: release the
    /// waiters (the load has settled as far as callers can tell) and replace
    /// the presumed-stale registration on the retry schedule.
    private func armSnapshotTimeout(generation: Int) {
        snapshotTimeoutTask?.cancel()
        let timeout = snapshotTimeout
        snapshotTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, generation == bindingGeneration, !chatSeeded else { return }
            snapshotTimeoutTask = nil
            AppLog.conversation.warning(
                "[ConversationStore] chat.subscribe snapshot did not arrive within \(timeout), resubscribing..."
            )
            resumeSnapshotWaiters()
            scheduleRetry(generation: generation)
        }
    }

    private func scheduleRetry(generation: Int) {
        retryTask?.cancel()
        let delay = nextRetryDelay ?? initialRetryDelay
        nextRetryDelay = min(delay * 2, maxRetryDelay)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, generation == bindingGeneration, let agentId else { return }
            // Cleared before `subscribe` cancels pending recovery, so this
            // task's own `chat.subscribe` request is not cancelled midway.
            retryTask = nil
            await releaseCurrentSubscription()
            await subscribe(agentId: agentId, workspaceId: workspaceId)
        }
    }

    func cancelSnapshotRecovery() {
        snapshotTimeoutTask?.cancel()
        snapshotTimeoutTask = nil
        retryTask?.cancel()
        retryTask = nil
    }

    func resetBackoff() {
        cancelSnapshotRecovery()
        nextRetryDelay = nil
    }

    // MARK: - Releasing registrations

    /// Unregisters and best-effort releases the current registration (whose
    /// seq-0 never arrived, or whose sequence broke) ahead of a fresh one.
    private func releaseCurrentSubscription() async {
        guard let subscriptionId = chatSubscriptionId else { return }
        connectionManager.unregisterSubscriptionHandler(id: subscriptionId)
        chatSubscriptionId = nil
        do {
            _ = try await connectionManager.request("chat.unsubscribe", params: [
                "subscriptionId": subscriptionId
            ])
        } catch {
            AppLog.conversation.error(
                "[ConversationStore] chat.unsubscribe failed: \(error)"
            )
        }
    }

    /// Best-effort release of a subscription the daemon opened for a binding
    /// we have since left, so it does not keep pushing for the old agent.
    private func releaseOrphanedSubscription(_ subscriptionId: String) async {
        guard subscriptionId != chatSubscriptionId else { return }
        do {
            _ = try await connectionManager.request("chat.unsubscribe", params: [
                "subscriptionId": subscriptionId
            ])
        } catch {
            AppLog.conversation.error(
                "[ConversationStore] chat.unsubscribe of orphaned \(subscriptionId) failed: \(error)"
            )
        }
    }

    private func clearChannel() {
        chatChannelActive = false
        chatLive = false
        chatSubscriptionId = nil
        resumeSnapshotWaiters()
    }
}
