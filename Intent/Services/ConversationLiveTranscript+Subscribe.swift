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
        let field = #"(?:`deltaencoding`|"deltaencoding"|'deltaencoding'|deltaencoding(?=$|[\s,;:()]|\.(?:\s|$)))"#
        return [
            #"\b(?:unknown|unrecognized|unsupported|unexpected)\s+(?:field|parameter)(?:\s*:\s*|\s+)\#(field)"#,
            #"(?:^|:\s*)(?:(?:field|parameter)\s+)?\#(field)\s+(?:is\s+)?not\s+supported\b"#
        ].contains { message.range(of: $0, options: .regularExpression) != nil }
    }

    private func openRegistration() -> Int {
        cancelSnapshotRecovery()
        releaseActiveRegistration()
        chatChannel = .registering
        incrementalDeltas = false
        registrationGeneration &+= 1
        return registrationGeneration
    }

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
                snapshotPending = false
                isLoading = false
                resumeSnapshotWaiters()
            }
            scheduleRetry(generation: generation)
        }
    }

    func resnapshot(for generation: Int) async {
        guard generation == registrationGeneration else { return }
        cancelSnapshotRecovery()
        if chatChannel == .live { chatChannel = .registering }
        incrementalDeltas = false

        await releaseCurrentSubscription()

        guard generation == registrationGeneration, let agentId else { return }
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
        registrationGeneration &+= 1
        resetBackoff()
    }

    // MARK: - Snapshot wait, timeout and backoff retry

    func awaitSnapshot() async {
        guard snapshotPending, !Task.isCancelled else { return }
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
        defer { deadline.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume()
                    return
                }
                snapshotWaiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.snapshotWaiters.removeValue(forKey: id)?.resume()
            }
        }
    }

    func resumeSnapshotWaiters() {
        let waiters = snapshotWaiters
        snapshotWaiters = [:]
        for waiter in waiters.values {
            waiter.resume()
        }
    }

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
        subscriptionLoadingStage = .retrying(attempt: subscriptionAttempt + 1)
        retryTask?.cancel()
        let delay = nextRetryDelay ?? initialRetryDelay
        traceEvent("ChatRetryScheduled", "requestRegistration=\(generation) attempt=\(subscriptionAttempt + 1) delaySeconds=\(delay.components.seconds)")
        nextRetryDelay = min(delay * 2, maxRetryDelay)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, generation == registrationGeneration else { return }
            await releaseCurrentSubscription()
            guard !Task.isCancelled, generation == registrationGeneration, let agentId else { return }
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

    func releaseActiveRegistration() {
        guard let subscriptionId = chatSubscriptionId else { return }
        connectionManager.unregisterSubscriptionHandler(id: subscriptionId)
        chatSubscriptionId = nil
        Self.release(subscriptionId, via: connectionManager)
    }

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
        chatChannel = .inactive
        chatSubscriptionId = nil
    }
}
