import Foundation
import SwiftUI

extension ConversationStore {
    // MARK: - Streaming subscription

    @discardableResult
    func bindStreaming(agentId: String, workspaceId: String?) -> Int {
        if streamingEventsActive, self.agentId == agentId, self.workspaceId == workspaceId {
            return eventRegistrationGeneration
        }
        deactivateStreaming()
        bindAgent(agentId)
        self.workspaceId = workspaceId
        streamingEventsActive = true
        metadataReadyForEntry = false
        needsFeedReconciliation = connectionManager.globalSubscriptionState != .subscribed
        let generation = eventRegistrationGeneration
        eventHandlerId = connectionManager.onEvent { [weak self] method, params in
            guard let self, ownsStreamingRegistration(generation) else { return }
            handleStreamEvent(method, params: params)
        }
        return generation
    }

    @discardableResult
    func subscribeToStreaming(agentId: String, workspaceId: String) -> Int? {
        guard !Task.isCancelled else { return nil }
        return bindStreaming(agentId: agentId, workspaceId: workspaceId)
    }

    func deactivateStreaming() {
        eventRegistrationGeneration &+= 1
        cancelBootstrap()
        cancelMetadataRefreshes()
        pendingWorkspaceEvents.removeAll()
        streamingEventsActive = false
        if let eventHandlerId { connectionManager.removeEventHandler(id: eventHandlerId) }
        eventHandlerId = nil
        liveTranscript.releaseActiveRegistration()
        liveTranscript.prepareForReconnect()
        liveTranscript.snapshotPending = false
        liveTranscript.resumeSnapshotWaiters()
        clearPendingQuestionRecovery()
    }

    // MARK: - Live chat subscription

    func subscribeLiveChat(agentId: String, workspaceId: String? = nil) async {
        bindAgent(agentId)
        if let workspaceId {
            self.workspaceId = workspaceId
        }
        await liveTranscript.subscribe(agentId: agentId, workspaceId: self.workspaceId)
        reconcilePendingQuestionRecovery()
    }

    func awaitLiveChatSnapshot() async {
        await liveTranscript.awaitSnapshot()
        reconcilePendingQuestionRecovery()
    }

    func handleChatSubscriptionPush(_ push: SubscriptionPush) {
        liveTranscript.handlePush(push)
    }

    func ownsStreamingRegistration(_ generation: Int) -> Bool {
        streamingEventsActive && generation == eventRegistrationGeneration
    }

    func handleStreamEvent(_ method: String, params: Any, ignoringMarkers: Set<String> = [], receivedAt: Int? = nil) {
        guard let dict = params as? [String: Any] else { return }

        if let push = SubscriptionPush.parse(method: method, params: params) {
            handleChatSubscriptionPush(push)
            return
        }

        guard !shouldIgnoreStreamEvent(dict) else { return }

        let event: [String: Any]
        if let innerEvent = dict["event"] as? [String: Any] {
            event = innerEvent
        } else {
            event = dict
        }

        guard let eventType = event["type"] as? String,
              let data = event["data"] as? [String: Any] else { return }

        let eventAgentId = data["agentId"] as? String
        let receivedAt = receivedAt ?? commands.agentDetails.nextStateSequence()
        if workspaceId == nil, bootstrapWorkspaceHint != nil, eventAgentId == agentId {
            if eventType == "agent:queue:updated" || eventType == "agent:queue:processing" { commands.queueMutations.beginDeferring() }
            pendingWorkspaceEvents.append(PendingWorkspaceEvent(
                event: event, receivedAt: receivedAt, confirmedMarkerRevisions: commands.confirmedMarkerRevisions
            ))
            scheduleMetadataRefresh()
            return
        }
        guard shouldContinueAfterWorkspaceEvent(
            eventType,
            data: data,
            eventAgentId: eventAgentId
        ) else { return }

        if eventType == "agent:updated" {
            handleAgentUpdated(data, ignoringMarkers: ignoringMarkers)
            return
        }

        handleAgentStreamEvent(eventType, data: data, receivedAt: receivedAt)
    }

    private func shouldContinueAfterWorkspaceEvent(
        _ eventType: String,
        data: [String: Any],
        eventAgentId: String?
    ) -> Bool {
        switch eventType {
        case "agent:deleted":
            if let agentId, eventAgentId == agentId {
                agentNotFound = true
                clearPendingQuestionRecovery()
            }
            handleWatchedDeletion(eventAgentId)
            return false
        case "agent:subscribed", "agent:unsubscribed", "agent:woken-by-subscription":
            refreshSubscriptions()
        case "agent:status-changed", "agent:idle":
            if let eventAgentId {
                watchedAgentCoordinator.handleStatusChange(agentId: eventAgentId)
            }
            refreshSubscriptions()
        case "agent:stream:activity":
            if let eventAgentId {
                watchedAgentCoordinator.handleActivity(
                    agentId: eventAgentId,
                    lastAgentResponse: data["lastAgentResponse"] as? String,
                    digest: data["digest"] as? String
                )
            }
        case "agent:stream:end":
            if let eventAgentId {
                watchedAgentCoordinator.handleStreamEnd(agentId: eventAgentId)
            }
        default:
            break
        }
        return eventAgentId == agentId
    }

    private func handleWatchedDeletion(_ eventAgentId: String?) {
        guard let eventAgentId, watchedAgentIds.contains(eventAgentId) else { return }
        watchedAgentCoordinator.handleStatusChange(agentId: eventAgentId)
        refreshSubscriptions()
    }

    private func refreshSubscriptions() {
        invalidateSubscriptions()
    }

    private func handleAgentStreamEvent(_ eventType: String, data: [String: Any], receivedAt: Int) {
        switch eventType {
        case "agent:stream:start", "agent:stream:activity":
            if !liveTranscript.chatLive { isStreaming = true }
        case "agent:stream:end":
            if !liveTranscript.chatLive { isStreaming = false }
        case "agent:queue:updated":
            handleQueueUpdated(data, receivedAt: receivedAt)
        case "agent:queue:processing":
            handleQueueProcessing(data, receivedAt: receivedAt)
        case "agent:user-message:sent":
            handleUserMessageSent(data)
        case "agent:status-changed":
            handleAgentStatusChanged(data)
        case "agent:idle":
            handleAgentIdle()
        default:
            break
        }
    }

    private func handleAgentStatusChanged(_ data: [String: Any]) {
        let newStatus = data["status"] as? String ?? data["newStatus"] as? String
        let status = newStatus?.lowercased() ?? ""
        if status == "responding" || status == "streaming" || status == "processing" {
            isStreaming = true
        } else if status == "idle" || status == "completed" || status == "failed" || status == "error" {
            isStreaming = false
        }
        refreshStateAfterTurnBoundary()
    }

    private func handleAgentIdle() {
        isStreaming = false
        refreshStateAfterTurnBoundary()
    }

    private func refreshStateAfterTurnBoundary() {
        guard let agentId else { return }
        let liveStateVersion = liveTranscript.liveStateVersion
        commands.agentDetails.invalidate(agentId: agentId)
        scheduleMetadataRefresh(liveStateVersion: liveStateVersion)
    }

    private func shouldIgnoreStreamEvent(_ event: [String: Any]) -> Bool {
        if let myAgentId = agentId {
            let inner = event["event"] as? [String: Any]
            let envelope = inner ?? event
            let eventData = envelope["data"] as? [String: Any] ?? envelope
            let eventAgentId = eventData["agentId"] as? String ?? envelope["agentId"] as? String
            if let eventAgentId,
               eventAgentId != myAgentId,
               !watchedAgentIds.contains(eventAgentId) {
                return true
            }
        }

        let envelope = event["event"] as? [String: Any] ?? event
        let data = envelope["data"] as? [String: Any] ?? [:]
        if let workspace = (data["workspaceId"] ?? envelope["workspaceId"]) as? String,
           let workspaceId, workspace != workspaceId, data["agentId"] as? String == agentId { return true }
        if let child = data["agentId"] as? String, child != agentId, watchedAgentIds.contains(child),
           let workspace = (data["workspaceId"] ?? envelope["workspaceId"]) as? String,
           let known = watchedAgentCoordinator.row(child).workspaceId, workspace != known { return true }
        return false
    }

    private func handleAgentUpdated(_ data: [String: Any], ignoringMarkers: Set<String>) {
        sessionMetadataGeneration += 1
        if AgentDetailStore.requiresReconciliation(data) { scheduleMetadataRefresh() }
        if !ignoringMarkers.contains("pendingQuestionsMessageId"), let pendingId = data["pendingQuestionsMessageId"] as? String {
            pendingQuestionsMessageId = pendingId
        }
        if !ignoringMarkers.contains("dismissedQuestionsMessageId"), let dismissedId = data["dismissedQuestionsMessageId"] as? String {
            dismissedQuestionsMessageId = dismissedId
        }
        if data.keys.contains("goal"), let eventAgentId = data["agentId"] as? String, eventAgentId == agentId {
            applyGoal(ConversationGoal.parse(data["goal"]), for: eventAgentId)
        }
        if !ignoringMarkers.contains("lastSeenMessageId"), let seenId = data["lastSeenMessageId"] as? String {
            lastSeenMessageId = seenId
            metadataReadyForEntry = connectionManager.globalSubscriptionState == .subscribed
        }
        notifyEntryStateChanged()
        reconcilePendingQuestionRecovery()
    }

    private func handleQueueUpdated(_ data: [String: Any], receivedAt: Int) {
        guard !commands.queueSeedSupersedes(receivedAt) else { return }
        if let decoded = ConversationCommands.decodeQueueSnapshot(
            data["queue"],
            source: "agent:queue:updated"
        ) {
            commands.applyQueueEvent(decoded, receivedAt: receivedAt)
            return
        }
        refreshQueue()
    }

    private func handleQueueProcessing(_ data: [String: Any], receivedAt: Int) {
        guard !commands.queueSeedSupersedes(receivedAt) else { return }
        if let messageId = data["messageId"] as? String {
            commands.removeProcessingMessage(messageId, receivedAt: receivedAt)
        } else {
            refreshQueue()
        }
    }

    private func handleUserMessageSent(_ data: [String: Any]) {
        guard let messageId = data["messageId"] as? String,
              let content = data["content"] as? String else { return }
        confirmSendAttempt(messageId, status: .accepted, confirmedMessageId: messageId)
        guard !messages.contains(where: { $0.id == messageId }) else { return }

        let userMessage = ConversationMessage(
            id: messageId,
            role: .user,
            contentBlocks: [ContentBlock(id: "\(messageId):0", type: .text, text: content)]
        )
        withAnimation(.spring(
            response: Constants.Conversation.Sending.messageAppendSpringResponse,
            dampingFraction: Constants.Conversation.Sending.messageAppendSpringDamping
        )) {
            messages.append(userMessage)
        }
    }
}
