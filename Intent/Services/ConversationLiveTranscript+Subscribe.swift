import Foundation

extension ConversationLiveTranscript {
    enum LoadingStage: Equatable {
        case idle
        case connecting
        case requesting
        case receiving
        case retrying(attempt: Int)
    }

    var loadingStage: LoadingStage {
        guard isLoading else { return .idle }
        guard connectionManager.connectionState == .connected else { return .connecting }
        return subscriptionLoadingStage
    }

    /// Bypasses snapshot/backoff waits. Supersede the old registration before
    /// releasing it so late replies and already-running recovery cannot win.
    func retryNow() async {
        guard agentId != nil, !Task.isCancelled else { return }
        cancelSnapshotRecovery()
        registrationGeneration &+= 1
        guard connectionManager.connectionState == .connected else {
            prepareForReconnect()
            connectionManager.retryConnection()
            return
        }
        await resnapshot(for: registrationGeneration)
    }

    /// Registers the sole transcript source: `chat.subscribe`, whose seq-0
    /// snapshot replaces the transcript and whose deltas keep it current.
    /// Returns once the registration is acked (its snapshot is then awaited
    /// through `awaitSnapshot`, bounded by `snapshotTimeout`) or rejected (a
    /// backoff retry is then scheduled). A registration opened over an empty
    /// transcript raises `isLoading` until its snapshot lands.
    func subscribe(agentId: String, workspaceId: String? = nil) async {
        if self.agentId != agentId { subscriptionAttempt = 0 }
        bind(agentId: agentId, workspaceId: workspaceId)
        let generation = openRegistration()
        subscriptionAttempt += 1
        subscriptionLoadingStage = .requesting
        snapshotPending = true
        if messages.isEmpty {
            isLoading = true
        }
        let interval = ConversationTrace.begin("ChatSubscribe", "\(traceContext) attempt=\(subscriptionAttempt)")
        defer { ConversationTrace.end("ChatSubscribe", interval, "\(traceContext) requestRegistration=\(generation)") }

        let outcome: Result<String?, Error>
        do {
            let result = try await requestSubscription(agentId: agentId, generation: generation)
            outcome = .success((result as? [String: Any])?["subscriptionId"] as? String)
        } catch {
            outcome = .failure(error)
        }
        // A reply (or failure) that lands after a rebind, reset, reconnect or
        // newer registration must leave the current channel untouched.
        guard generation == registrationGeneration else {
            traceEvent("ChatSubscribeRejected", "reason=registration_changed requestRegistration=\(generation)")
            if case .success(let orphanedId?) = outcome {
                await releaseOrphanedSubscription(orphanedId)
            }
            return
        }
        applySubscribeOutcome(outcome, generation: generation)
    }

    private func requestSubscription(agentId: String, generation: Int) async throws -> Any {
        var params: [String: Any] = [
            "agentId": agentId,
            "replaceGroup": "ios-chat-\(agentId)",
            "projection": "slim",
            "limit": Self.initialHistoryMessageLimit
        ]
        if !useFullDeltaEncoding { params["deltaEncoding"] = "incremental" }
        do {
            return try await sendSubscriptionRequest(params, generation: generation)
        } catch {
            guard generation == registrationGeneration, !useFullDeltaEncoding,
                  Self.rejectsDeltaEncoding(error) else { throw error }
            // Retry only this known optional-field rejection, once. Normal
            // recovery keeps omitting it until reconnect negotiates anew.
            useFullDeltaEncoding = true
            params.removeValue(forKey: "deltaEncoding")
            traceEvent("ChatSubscribeFallback", "reason=unsupported_encoding requestRegistration=\(generation)")
            return try await sendSubscriptionRequest(params, generation: generation)
        }
    }

    private func sendSubscriptionRequest(_ params: [String: Any], generation: Int) async throws -> Any {
        let interval = ConversationTrace.begin(
            "ChatSubscribeRequest",
            "\(traceContext) requestRegistration=\(generation) incremental=\(params["deltaEncoding"] != nil)"
        )
        var succeeded = false
        defer {
            ConversationTrace.end(
                "ChatSubscribeRequest",
                interval,
                "\(traceContext) requestRegistration=\(generation) succeeded=\(succeeded) cancelled=\(Task.isCancelled)"
            )
        }
        let result = try await connectionManager.request("chat.subscribe", params: params)
        succeeded = true
        traceEvent(
            "ChatSubscribeResponse",
            "requestRegistration=\(generation) hasSubscriptionID=\((result as? [String: Any])?["subscriptionId"] is String)"
        )
        return result
    }

    private static let initialHistoryMessageLimit = 50
    private static let invalidParametersCode = -32_602

    private static func rejectsDeltaEncoding(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == "WebSocket", error.code == invalidParametersCode else { return false }
        let message = error.localizedDescription.lowercased()
        // Bind the rejection to this exact parameter. Its name in an
        // expected-field list or another clause is not a compatibility signal.
        let field = #"(?:`deltaencoding`|"deltaencoding"|'deltaencoding'|deltaencoding(?=$|[\s,;:()]|\.(?:\s|$)))"#
        return [
            #"\b(?:unknown|unrecognized|unsupported|unexpected)\s+(?:field|parameter)(?:\s*:\s*|\s+)\#(field)"#,
            #"(?:^|:\s*)(?:(?:field|parameter)\s+)?\#(field)\s+(?:is\s+)?not\s+supported\b"#
        ].contains { message.range(of: $0, options: .regularExpression) != nil }
    }

    /// Opens a registration: the current channel is released (its handler
    /// no longer reaches `handlePush` and its daemon-side subscription is
    /// let go without waiting), pending self-heal is dropped, and the token
    /// the new registration's reply, handler, timeout and retry validate
    /// against is returned. The recovery paths release before they get here,
    /// so a registration they replace is released exactly once. A released
    /// channel no longer owns liveness: the firehose does until the new
    /// registration's snapshot applies.
    private func openRegistration() -> Int {
        cancelSnapshotRecovery()
        releaseActiveRegistration()
        chatChannel = .registering
        incrementalDeltas = false
        registrationGeneration &+= 1
        return registrationGeneration
    }

    /// Registers the acked subscription's handler and arms the seq-0 snapshot
    /// timeout, or clears the channel and schedules a backoff retry when the
    /// registration was rejected.
    private func applySubscribeOutcome(_ outcome: Result<String?, Error>, generation: Int) {
        switch outcome {
        case .success(let subscriptionId?):
            traceEvent("ChatSubscribeAccepted", "requestRegistration=\(generation)")
            chatSubscriptionId = subscriptionId
            connectionManager.registerSubscriptionHandler(id: subscriptionId) { [weak self] push in
                guard let self else { return }
                guard generation == registrationGeneration else {
                    traceEvent("ChatPushRejected", "reason=registration_changed requestRegistration=\(generation)")
                    return
                }
                handlePush(push)
            }
            AppLog.conversation.info(
                "[ConversationStore] Subscribed to chat.subscribe: \(subscriptionId)"
            )
            // A snapshot that raced the ack has already seeded the channel.
            guard !chatSeeded else { return }
            subscriptionLoadingStage = .receiving
            armSnapshotTimeout(generation: generation)
        case .success(nil):
            traceEvent("ChatSubscribeRejected", "reason=missing_subscription_id requestRegistration=\(generation)")
            clearChannel()
            AppLog.conversation.warning(
                "[ConversationStore] chat.subscribe returned no subscriptionId, retrying with backoff"
            )
            scheduleRetry(generation: generation)
        case .failure(let error):
            traceEvent(
                "ChatSubscribeRejected",
                "reason=request_failed requestRegistration=\(generation) entityMissing=\((error as NSError).isEntityNotFound) cancelled=\(Task.isCancelled)"
            )
            clearChannel()
            AppLog.conversation.warning(
                "[ConversationStore] chat.subscribe failed: \(error), retrying with backoff"
            )
            onSubscribeError?(error)
            if (error as NSError).isEntityNotFound {
                // The bound agent is gone: no snapshot will come, so the
                // load settles now rather than at the wait's deadline.
                snapshotPending = false
                isLoading = false
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
        if chatChannel == .live { chatChannel = .registering }
        incrementalDeltas = false

        await releaseCurrentSubscription()

        guard generation == registrationGeneration, let agentId else { return }
        // Opening the replacement advances the generation, which ends this
        // recovery's ownership.
        await subscribe(agentId: agentId, workspaceId: workspaceId)
    }

    func prepareForReconnect() {
        traceEvent("ChatReconnecting", "messages=\(messages.count) pending=\(snapshotPending)")
        subscriptionLoadingStage = .requesting
        incrementalDeltas = false
        useFullDeltaEncoding = false
        if let subscriptionId = chatSubscriptionId {
            connectionManager.unregisterSubscriptionHandler(id: subscriptionId)
        }
        chatSubscriptionId = nil
        chatChannel = .inactive
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
        let interval = ConversationTrace.begin("ChatSnapshotWait", traceContext)
        defer { ConversationTrace.end("ChatSnapshotWait", interval, "\(traceContext) seeded=\(chatSeeded) pending=\(snapshotPending)") }
        let id = UUID()
        let timeout = snapshotTimeout
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.traceEvent("ChatSnapshotWaitExpired", "")
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
            traceEvent("ChatSnapshotTimeout", "requestRegistration=\(generation)")
            AppLog.conversation.warning(
                "[ConversationStore] chat.subscribe snapshot did not arrive within \(timeout), resubscribing..."
            )
            scheduleRetry(generation: generation)
        }
    }

    private func scheduleRetry(generation: Int) {
        // Include the initial registration: the first retry is attempt 2.
        subscriptionLoadingStage = .retrying(attempt: subscriptionAttempt + 1)
        retryTask?.cancel()
        let delay = nextRetryDelay ?? initialRetryDelay
        traceEvent("ChatRetryScheduled", "requestRegistration=\(generation) attempt=\(subscriptionAttempt + 1) delaySeconds=\(delay.components.seconds)")
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
        subscriptionAttempt = 0
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

    /// Unbind (rebind, `reset`): detaches the acked registration and releases
    /// it daemon-side without waiting. Nothing observes the reply, so a
    /// release that resolves or fails late cannot touch a later binding. A
    /// pending or rejected registration has nothing to release; its late ack
    /// goes through `releaseOrphanedSubscription`.
    func releaseActiveRegistration() {
        guard let subscriptionId = chatSubscriptionId else { return }
        connectionManager.unregisterSubscriptionHandler(id: subscriptionId)
        chatSubscriptionId = nil
        Self.release(subscriptionId, via: connectionManager)
    }

    /// Fire-and-forget `chat.unsubscribe`. Static so `deinit` can release
    /// the active registration without retaining `self`.
    static func release(_ subscriptionId: String, via connectionManager: ConnectionManagerRouting) {
        Task {
            do {
                _ = try await connectionManager.request("chat.unsubscribe", params: [
                    "subscriptionId": subscriptionId
                ])
            } catch {
                AppLog.conversation.error(
                    "[ConversationStore] chat.unsubscribe of released \(subscriptionId) failed: \(error)"
                )
            }
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
        chatChannel = .inactive
        chatSubscriptionId = nil
    }
}
