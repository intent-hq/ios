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
        let generation = openRegistration()
        chatChannelActive = true
        chatSeeded = false
        snapshotPending = true
        if messages.isEmpty {
            isLoading = true
        }

        let outcome: Result<String?, Error>
        do {
            let result = try await connectionManager.request("chat.subscribe", params: [
                "agentId": agentId,
                "replaceGroup": "ios-chat-\(agentId)",
                "projection": "slim"
            ])
            outcome = .success((result as? [String: Any])?["subscriptionId"] as? String)
        } catch {
            outcome = .failure(error)
        }
        // A reply (or failure) that lands after a rebind, reset, reconnect or
        // newer registration must leave the current channel untouched.
        guard generation == registrationGeneration else {
            if case .success(let orphanedId?) = outcome {
                await releaseOrphanedSubscription(orphanedId)
            }
            return
        }
        applySubscribeOutcome(outcome, generation: generation)
    }

    /// Opens a registration: the current channel is detached (its handler
    /// no longer reaches `handlePush`, though its daemon-side release stays
    /// with the recovery paths), pending self-heal is dropped, and the token
    /// the new registration's reply, handler, timeout and retry validate
    /// against is returned.
    private func openRegistration() -> Int {
        cancelSnapshotRecovery()
        if let previous = chatSubscriptionId {
            connectionManager.unregisterSubscriptionHandler(id: previous)
            chatSubscriptionId = nil
        }
        registrationGeneration &+= 1
        return registrationGeneration
    }

    /// Registers the acked subscription's handler and arms the seq-0 snapshot
    /// timeout, or clears the channel and schedules a backoff retry when the
    /// registration was rejected.
    private func applySubscribeOutcome(_ outcome: Result<String?, Error>, generation: Int) {
        switch outcome {
        case .success(let subscriptionId?):
            chatSubscriptionId = subscriptionId
            connectionManager.registerSubscriptionHandler(id: subscriptionId) { [weak self] push in
                guard let self, generation == registrationGeneration else { return }
                handlePush(push)
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
            if (error as NSError).isEntityNotFound {
                // The bound agent is gone: no snapshot will come, so the
                // load settles now rather than at the wait's deadline.
                snapshotPending = false
                resumeSnapshotWaiters()
            }
            scheduleRetry(generation: generation)
        }
    }

    /// Gap / rejected-empty-snapshot recovery of the registration `generation`:
    /// a fresh registration whose seq-0 snapshot replaces the transcript.
    /// There is no page fetch to fall back on; a registration that fails or
    /// stays silent self-heals on the retry schedule inside `subscribe`. A
    /// recovery whose registration was superseded before it ran, or while it
    /// released the old subscription, does nothing: the newer registration
    /// (or `reset` / reconnect) owns recovery now, and its own gaps schedule
    /// a recovery of their own since `recoveryGeneration` no longer matches.
    func resnapshot(for generation: Int) async {
        guard generation == registrationGeneration else { return }
        // This recovery owns the channel: a timeout or retry armed for the
        // registration it replaces must not open a registration of its own.
        cancelSnapshotRecovery()
        chatLive = false
        chatSeeded = false

        await releaseCurrentSubscription()

        guard generation == registrationGeneration, let agentId else { return }
        // Opening the replacement advances the generation, which ends this
        // recovery's ownership.
        await subscribe(agentId: agentId, workspaceId: workspaceId)
    }

    func prepareForReconnect() {
        chatLive = false
        if let subscriptionId = chatSubscriptionId {
            connectionManager.unregisterSubscriptionHandler(id: subscriptionId)
        }
        chatSubscriptionId = nil
        chatChannelActive = false
        chatSeeded = false
        recoveryGeneration = nil
        emptySnapshotRecoveryAttempts = 0
        // The reconnect registration is the recovery: drop the outage's
        // in-flight replies and pending retry, and start the backoff over.
        // Snapshot waiters keep parking for that registration's snapshot.
        registrationGeneration &+= 1
        resetBackoff()
    }

    // MARK: - Snapshot wait, timeout and backoff retry

    /// Parks until the owed seq-0 snapshot applies, the binding is torn down
    /// (rebind, reset), or `snapshotTimeout` elapses. A rejected or silent
    /// registration and a reconnect keep the wait open: their re-registration
    /// serves the snapshot within the bound. Returns at once when no snapshot
    /// is owed.
    func awaitSnapshot() async {
        guard snapshotPending else { return }
        let id = UUID()
        let timeout = snapshotTimeout
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.snapshotWaiters.removeValue(forKey: id)?.resume()
        }
        await withCheckedContinuation { continuation in
            snapshotWaiters[id] = continuation
        }
        deadline.cancel()
    }

    func resumeSnapshotWaiters() {
        let waiters = snapshotWaiters
        snapshotWaiters = [:]
        for waiter in waiters.values {
            waiter.resume()
        }
    }

    /// The registration acked but its seq-0 snapshot never came: replace the
    /// presumed-stale registration on the retry schedule. Waiters keep
    /// parking for the replacement, bounded by their own deadline.
    private func armSnapshotTimeout(generation: Int) {
        snapshotTimeoutTask?.cancel()
        let timeout = snapshotTimeout
        snapshotTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, generation == registrationGeneration, !chatSeeded else { return }
            snapshotTimeoutTask = nil
            AppLog.conversation.warning(
                "[ConversationStore] chat.subscribe snapshot did not arrive within \(timeout), resubscribing..."
            )
            scheduleRetry(generation: generation)
        }
    }

    private func scheduleRetry(generation: Int) {
        retryTask?.cancel()
        let delay = nextRetryDelay ?? initialRetryDelay
        nextRetryDelay = min(delay * 2, maxRetryDelay)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, generation == registrationGeneration else { return }
            // Still cancellable through `retryTask` across the release; a
            // reset, rebind, reconnect or explicit registration meanwhile
            // owns recovery and this retry must not revive its binding.
            await releaseCurrentSubscription()
            guard !Task.isCancelled, generation == registrationGeneration, let agentId else { return }
            // Cleared before `subscribe` cancels pending recovery, so this
            // task's own `chat.subscribe` request is not cancelled midway.
            retryTask = nil
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

    /// A rejected registration leaves no channel; its snapshot stays owed to
    /// the retry, so waiters are not released here.
    private func clearChannel() {
        chatChannelActive = false
        chatLive = false
        chatSubscriptionId = nil
    }
}
