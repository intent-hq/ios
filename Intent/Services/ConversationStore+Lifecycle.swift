import Combine
import Foundation

extension ConversationStore {
    /// Test-only helper: activate the chat channel and set its subscriptionId,
    /// bypassing the real subscribe flow, so the strict push gate accepts test payloads.
    func setTestChatChannel(subscriptionId: String) {
        liveTranscript.setTestChannel(subscriptionId: subscriptionId)
    }

    // MARK: - Connection observation

    func observeConnection() {
        connectionObserver = connectionManager.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state == .connected {
                    Task { await self?.onReconnected() }
                }
            }
    }

    private func onReconnected() async {
        liveTranscript.prepareForReconnect()

        guard let agentId else { return }
        async let conv: () = fetchConversation(agentId: agentId, workspaceId: workspaceId)
        async let queue: () = fetchQueue(agentId: agentId)
        async let streaming: () = fetchAgentStreamingState(agentId: agentId)
        _ = await (conv, queue, streaming)
        if let workspaceId {
            await subscribeToStreaming(agentId: agentId, workspaceId: workspaceId)
            await subscribeLiveChat(agentId: agentId)
            await fetchSubscriptions(agentId: agentId, workspaceId: workspaceId)
        }
    }

    /// Fetch the agent's current state via `agent.get` and restore `isStreaming`.
    /// Considers the STAB-125 `turnInFlight` turn-liveness flag alongside
    /// `isStreaming`/`isResponding` (the headless daemon reports liveness via
    /// `turnInFlight`; `isStreaming`/`isResponding` may always be false).
    /// With `raiseOnly` the flag is only ever raised, never cleared — used as a
    /// backstop on view load so it cannot clobber snapshot/optimistic state.
    /// The pending attention request is always taken from the server response
    /// (raise or clear) — it is server-authoritative with no optimistic state.
    /// A reply (or error) that lands while the store is bound to a different
    /// agent than the one the request was issued for — or unbound by a
    /// `reset()` since the request was issued — is dropped entirely: it must
    /// not touch the new conversation's streaming/attention state, nor mark
    /// the new agent deleted on a not-found for the previous one. A request
    /// issued while still unbound (view load, before `fetchConversation`
    /// binds the same agent) stays valid.
    /// The session-metadata markers are additionally skipped when an
    /// `agent:updated` push landed, or the bound agent changed (agent switch /
    /// `reset`), while the request was in flight: the reply predates the
    /// change, so applying it would revert the newer marker or leak the
    /// previous agent's markers into the new conversation.
    /// With `liveStateVersion`, the streaming flag is also left alone when the
    /// live chat channel advanced past that version while the request was in
    /// flight: the channel is authoritative and the reply predates it.
    func fetchAgentStreamingState(
        agentId: String,
        raiseOnly: Bool = false,
        liveStateVersion: Int? = nil
    ) async {
        let generation = sessionMetadataGeneration
        let boundAtIssue = self.agentId
        do {
            if let state = try await commands.fetchAgentState(agentId: agentId) {
                guard isBound(to: agentId, boundAtIssue: boundAtIssue) else { return }
                let liveStateMoved = liveStateVersion.map { $0 != liveTranscript.liveStateVersion } ?? false
                if liveStateMoved {
                    AppLog.conversation.debug(
                        "[ConversationStore] Live channel advanced during agent.get; keeping its streaming state"
                    )
                } else if raiseOnly {
                    if state.isStreaming { isStreaming = true }
                } else {
                    isStreaming = state.isStreaming
                }
                attentionRequest = state.attentionRequest
                guard generation == sessionMetadataGeneration else { return }
                if let pendingId = state.pendingQuestionsMessageId {
                    pendingQuestionsMessageId = pendingId
                }
                if let dismissedId = state.dismissedQuestionsMessageId {
                    dismissedQuestionsMessageId = dismissedId
                }
                if let seenId = state.lastSeenMessageId { lastSeenMessageId = seenId }
                reconcilePendingQuestionRecovery()
            }
        } catch {
            if isBound(to: agentId, boundAtIssue: boundAtIssue) {
                raiseAgentNotFoundIfDefinitive(error)
            }
            AppLog.conversation.error("[ConversationStore] Failed to fetch agent streaming state: \(error)")
        }
    }

    private func isBound(to agentId: String, boundAtIssue: String?) -> Bool {
        self.agentId == agentId || (self.agentId == nil && boundAtIssue == nil)
    }

    func raiseAgentNotFoundIfDefinitive(_ error: Error) {
        let nsError = error as NSError
        if nsError.isEntityNotFound {
            AppLog.conversation.warning(
                "[ConversationStore] not-found for agent \(agentId ?? "?") — "
                    + "treating as deleted: \(nsError.localizedDescription)"
            )
            agentNotFound = true
        } else if nsError.domain == "WebSocket", nsError.code == Self.invalidParametersErrorCode {
            AppLog.conversation.error(
                "[ConversationStore] UNEXPECTED -32602 without data.code == \"not-found\" for "
                    + "agent \(agentId ?? "?") (data.code: \(nsError.intentErrorDataCode ?? "absent")) — "
                    + "NOT treating as deletion: \(nsError.localizedDescription)"
            )
        }
    }

    // MARK: - Fetch conversation

    func bindAgent(_ agentId: String?) {
        if let bound = self.agentId, bound != agentId {
            sessionMetadataGeneration += 1
        }
        self.agentId = agentId
    }

    func fetchConversation(agentId: String, workspaceId: String? = nil) async {
        bindAgent(agentId)
        if let workspaceId {
            self.workspaceId = workspaceId
        }
        await liveTranscript.fetchConversation(agentId: agentId, workspaceId: workspaceId)
        reconcilePendingQuestionRecovery()
    }

    // MARK: - Marked question recovery (aroundMessageId seek, PROTOCOL §5.5)

    func reconcilePendingQuestionRecovery() {
        guard case .set(let markedId) = PendingQuestionSet.MarkerState(pendingQuestionsMessageId),
              let agentId, !agentNotFound else {
            clearPendingQuestionRecovery()
            return
        }
        if let recovery = pendingQuestionRecovery, recovery.messageId != markedId {
            clearPendingQuestionRecovery()
        }
        if let resident = messages.first(where: { $0.id == markedId }) {
            if pendingQuestionRecovery?.status == .loading {
                pendingQuestionRecoveryTask?.cancel()
                pendingQuestionRecoveryTask = nil
                pendingQuestionRecovery = PendingQuestionRecovery(
                    messageId: markedId,
                    status: .found,
                    message: resident
                )
            }
            return
        }
        guard !isLoading, pendingQuestionRecovery == nil else { return }
        pendingQuestionRecovery = PendingQuestionRecovery(messageId: markedId, status: .loading)
        pendingQuestionRecoveryTask = Task { [weak self] in
            await self?.recoverMarkedQuestionMessage(agentId: agentId, messageId: markedId)
        }
    }

    func clearPendingQuestionRecovery() {
        pendingQuestionRecoveryTask?.cancel()
        pendingQuestionRecoveryTask = nil
        if pendingQuestionRecovery != nil { pendingQuestionRecovery = nil }
    }

    private func recoverMarkedQuestionMessage(agentId: String, messageId: String) async {
        let delays = markedQuestionRetryDelays
        for attempt in 0...delays.count {
            do {
                let message = try await commands.fetchMessage(
                    agentId: agentId,
                    messageId: messageId,
                    workspaceId: workspaceId
                )
                guard isPendingQuestionRecoveryCurrent(messageId) else { return }
                if let message {
                    settlePendingQuestionRecovery(messageId, status: .found, message: message)
                } else {
                    settlePendingQuestionRecovery(messageId, status: .notFound)
                }
                return
            } catch is CancellationError {
                return
            } catch {
                guard await handleMarkedQuestionRecoveryFailure(
                    error,
                    messageId: messageId,
                    attempt: attempt,
                    delays: delays
                ) else { return }
            }
        }
    }

    private func handleMarkedQuestionRecoveryFailure(
        _ error: Error,
        messageId: String,
        attempt: Int,
        delays: [Duration]
    ) async -> Bool {
        guard isPendingQuestionRecoveryCurrent(messageId) else { return false }
        let nsError = error as NSError
        if nsError.domain == "WebSocket", nsError.code == Self.invalidParametersErrorCode {
            if nsError.isEntityNotFound {
                raiseAgentNotFoundIfDefinitive(error)
                clearPendingQuestionRecovery()
                return false
            }
            AppLog.conversation.warning(
                "[ConversationStore] marked question message \(messageId) unknown to the daemon: "
                    + nsError.localizedDescription
            )
            settlePendingQuestionRecovery(messageId, status: .notFound)
            return false
        }
        guard attempt < delays.count else {
            AppLog.conversation.error(
                "[ConversationStore] Failed to recover marked question message \(messageId) "
                    + "after bounded retries: \(error)"
            )
            settlePendingQuestionRecovery(messageId, status: .error)
            return false
        }
        AppLog.conversation.warning(
            "[ConversationStore] Retrying marked question recovery for \(messageId) "
                + "(attempt \(attempt + 1)): \(error)"
        )
        do {
            try await Task.sleep(for: delays[attempt])
        } catch {
            return false
        }
        return isPendingQuestionRecoveryCurrent(messageId)
    }

    private func isPendingQuestionRecoveryCurrent(_ messageId: String) -> Bool {
        !Task.isCancelled
            && pendingQuestionRecovery?.messageId == messageId
            && pendingQuestionRecovery?.status == .loading
    }

    private func settlePendingQuestionRecovery(
        _ messageId: String,
        status: PendingQuestionRecovery.Status,
        message: ConversationMessage? = nil
    ) {
        pendingQuestionRecoveryTask = nil
        pendingQuestionRecovery = PendingQuestionRecovery(
            messageId: messageId,
            status: status,
            message: message
        )
    }

    // MARK: - Slim block hydration (agent.getMessageBlock, PROTOCOL §5.5)

    static func hydratedBlockKey(messageId: String, blockId: String) -> String {
        ConversationLiveTranscript.hydratedBlockKey(
            messageId: messageId,
            blockId: blockId
        )
    }

    func isBlockHydrated(messageId: String, blockId: String) -> Bool {
        liveTranscript.isBlockHydrated(messageId: messageId, blockId: blockId)
    }

    func hydratingBlockIds(forMessage messageId: String) -> Set<String> {
        liveTranscript.hydratingBlockIds(forMessage: messageId)
    }

    func hydrateBlock(messageId: String, blockId: String) async {
        await liveTranscript.hydrateBlock(messageId: messageId, blockId: blockId)
    }
}
