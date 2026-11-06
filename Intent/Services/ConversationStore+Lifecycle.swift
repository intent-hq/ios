import Combine
import Foundation

extension ConversationStore {
    /// Test-only helper: activate the chat channel and set its subscriptionId,
    /// bypassing the real subscribe flow, so the strict push gate accepts test payloads.
    func setTestChatChannel(subscriptionId: String) {
        liveTranscript.setTestChannel(subscriptionId: subscriptionId)
    }

    private struct MarkerRevisions {
        let pending: Int
        let dismissed: Int
        let seen: Int
    }

    // MARK: - Metadata reconciliation

    /// Fetch the agent's current state via `agent.get` and restore `isStreaming`.
    /// Considers the STAB-125 `turnInFlight` turn-liveness flag alongside
    /// `isStreaming`/`isResponding` (the headless daemon reports liveness via
    /// `turnInFlight`; `isStreaming`/`isResponding` may always be false).
    /// With `raiseOnly` the flag is only ever raised, never cleared — used as a
    /// backstop on view load so it cannot clobber snapshot/optimistic state.
    /// A reply (or error) that lands while the store is bound to a different
    /// agent than the one the request was issued for — or unbound by a
    /// `reset()` since the request was issued — is dropped entirely: it must
    /// not touch the new conversation's streaming state, nor mark
    /// the new agent deleted on a not-found for the previous one. A request
    /// issued while still unbound (view load, before `subscribeLiveChat`
    /// binds the same agent) stays valid.
    /// A marker changed by a push or local command during the read is kept.
    /// Untouched markers still seed from the detail, so an unrelated update
    /// cannot leave the entry seen marker or pending question unknown.
    /// With `liveStateVersion`, the streaming flag is also left alone when the
    /// live chat channel advanced past that version while the request was in
    /// flight: the channel is authoritative and the reply predates it.
    func fetchAgentStreamingState(
        agentId: String,
        raiseOnly: Bool = false,
        liveStateVersion: Int? = nil,
        refresh: Bool = true
    ) async {
        guard !Task.isCancelled else { return }
        let activation = eventRegistrationGeneration
        let binding = agentBindingGeneration
        let revisions = MarkerRevisions(
            pending: commands.pendingMarkerRevision,
            dismissed: commands.dismissedMarkerRevision,
            seen: commands.seenMarkerRevision
        )
        let issuedLiveVersion = liveStateVersion ?? liveTranscript.liveStateVersion
        let boundAtIssue = self.agentId
        do {
            if let state = try await commands.fetchAgentState(agentId: agentId, workspaceId: workspaceId, refresh: refresh) {
                guard !Task.isCancelled, activation == eventRegistrationGeneration,
                      binding == agentBindingGeneration, isBound(to: agentId, boundAtIssue: boundAtIssue) else { return }
                applyFetchedStreamingState(state.isStreaming, raiseOnly: raiseOnly, issuedAt: issuedLiveVersion)
                applyFetchedMarkers(state, revisions: revisions)
                resolveWorkspaceFromDetail()
                metadataReadyForEntry = !workspaceAuthority.hasFailed && connectionManager.globalSubscriptionState == .subscribed
                notifyEntryStateChanged()
                reconcilePendingQuestionRecovery()
            }
        } catch {
            guard !Task.isCancelled, activation == eventRegistrationGeneration, binding == agentBindingGeneration else { return }
            failWorkspaceAuthority()
            if isBound(to: agentId, boundAtIssue: boundAtIssue) { raiseAgentNotFoundIfDefinitive(error) }
            AppLog.conversation.error("[ConversationStore] Failed to fetch agent streaming state: \(error)")
        }
    }

    private func applyFetchedMarkers(_ state: ConversationCommands.AgentState, revisions: MarkerRevisions) {
        // Each marker has its own revision: a pending-question push must not
        // erase an otherwise authoritative entry seen marker (and vice versa).
        if revisions.pending == commands.pendingMarkerRevision, let pendingId = state.pendingQuestionsMessageId {
            pendingQuestionsMessageId = pendingId
        }
        if revisions.dismissed == commands.dismissedMarkerRevision, let dismissedId = state.dismissedQuestionsMessageId {
            dismissedQuestionsMessageId = dismissedId
        }
        if revisions.seen == commands.seenMarkerRevision, let seenId = state.lastSeenMessageId { lastSeenMessageId = seenId }
    }

    /// Event-triggered reads belong to this view activation, unlike independent
    /// route validation. Canceling them removes only their shared-detail interest.
    @discardableResult
    func scheduleMetadataRefresh(raiseOnly: Bool = true, liveStateVersion: Int? = nil) -> Task<Void, Never>? {
        guard let agentId else { return nil }
        let activation = eventRegistrationGeneration
        let taskID = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { metadataRefreshTasks[taskID] = nil }
            guard !Task.isCancelled, eventRegistrationGeneration == activation, self.agentId == agentId else { return }
            await fetchAgentStreamingState(agentId: agentId, raiseOnly: raiseOnly, liveStateVersion: liveStateVersion, refresh: false)
        }
        metadataRefreshTasks[taskID] = task
        return task
    }

    func cancelMetadataRefreshes() {
        for task in metadataRefreshTasks.values { task.cancel() }
        metadataRefreshTasks.removeAll()
    }

    private func applyFetchedStreamingState(_ streaming: Bool, raiseOnly: Bool, issuedAt liveStateVersion: Int?) {
        guard !liveTranscript.chatLive else { return }
        if let liveStateVersion, liveStateVersion != liveTranscript.liveStateVersion {
            AppLog.conversation.debug(
                "[ConversationStore] Live channel advanced during agent.get; keeping its streaming state"
            )
            return
        }
        if raiseOnly {
            if streaming { isStreaming = true }
        } else {
            isStreaming = streaming
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

    // MARK: - Binding

    func bindAgent(_ agentId: String?) {
        if let bound = self.agentId, bound != agentId {
            cancelBootstrap()
            cancelMetadataRefreshes()
            sessionMetadataGeneration += 1
            agentBindingGeneration &+= 1
        }
        self.agentId = agentId
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
