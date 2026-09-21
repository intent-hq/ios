import Foundation
import SwiftUI

extension ConversationStore {
    // MARK: - Streaming subscription

    func subscribeToStreaming(agentId: String, workspaceId: String) async {
        guard !isSubscribing else { return }
        isSubscribing = true
        defer { isSubscribing = false }

        bindAgent(agentId)
        self.workspaceId = workspaceId

        await unsubscribePrevious()

        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
        }

        eventHandlerId = connectionManager.onEvent { [weak self] method, params in
            Task { @MainActor [weak self] in
                self?.handleStreamEvent(method, params: params)
            }
        }

        do {
            subscriptionId = try await commands.subscribeToEvents(
                agentId: agentId,
                workspaceId: workspaceId
            )
            AppLog.conversation.info("[ConversationStore] Subscribed to streaming events")
        } catch {
            AppLog.conversation.error("[ConversationStore] Failed to subscribe: \(error)")
        }
    }

    // MARK: - Live chat subscription

    /// Opens the `chat.subscribe` channel that is the transcript's only
    /// source; returns once the registration is acked. Its seq-0 snapshot
    /// (or the snapshot timeout) is awaited via `awaitLiveChatSnapshot`.
    func subscribeLiveChat(agentId: String, workspaceId: String? = nil) async {
        bindAgent(agentId)
        if let workspaceId {
            self.workspaceId = workspaceId
        }
        await liveTranscript.subscribe(agentId: agentId, workspaceId: self.workspaceId)
        reconcilePendingQuestionRecovery()
    }

    /// Parks until the owed `chat.subscribe` seq-0 snapshot applied (a
    /// rejected or silent registration keeps it owed to the retry), the
    /// binding was torn down, or the wait's `snapshotTimeout` bound elapsed.
    func awaitLiveChatSnapshot() async {
        await liveTranscript.awaitSnapshot()
        reconcilePendingQuestionRecovery()
    }

    func handleChatSubscriptionPush(_ push: SubscriptionPush) {
        liveTranscript.handlePush(push)
    }

    private func unsubscribePrevious() async {
        guard let subId = subscriptionId else { return }
        subscriptionId = nil
        do {
            try await commands.unsubscribeEvents(subscriptionId: subId)
            AppLog.conversation.debug("[ConversationStore] Unsubscribed previous subscription: \(subId)")
        } catch {
            AppLog.conversation.error("[ConversationStore] Failed to unsubscribe: \(error)")
        }
    }

    func handleStreamEvent(_ method: String, params: Any) {
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
        guard shouldContinueAfterWorkspaceEvent(
            eventType,
            data: data,
            eventAgentId: eventAgentId
        ) else { return }

        if eventType == "agent:updated" {
            handleAgentUpdated(data)
            return
        }

        handleAgentStreamEvent(eventType, data: data)
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

    private func refreshSubscriptions() {
        if let agentId, let workspaceId {
            Task { await fetchSubscriptions(agentId: agentId, workspaceId: workspaceId) }
        }
    }

    /// `agent:stream:*` carries no transcript content: the `chat.subscribe`
    /// channel is the transcript's only source and owns the streaming flag
    /// once its snapshot applied (`chatLive`). Until then the firehose is the
    /// only liveness signal, so it raises and lowers the flag alone.
    private func handleAgentStreamEvent(_ eventType: String, data: [String: Any]) {
        switch eventType {
        case "agent:stream:start", "agent:stream:activity":
            if !liveTranscript.chatLive { isStreaming = true }
        case "agent:stream:end":
            if !liveTranscript.chatLive { isStreaming = false }
        case "agent:queue:updated":
            handleQueueUpdated(data)
        case "agent:queue:processing":
            handleQueueProcessing(data)
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
        if let agentId {
            Task { await fetchAgentStreamingState(agentId: agentId, raiseOnly: true) }
        }
    }

    private func handleAgentIdle() {
        isStreaming = false
        if let agentId {
            Task { await fetchAgentStreamingState(agentId: agentId, raiseOnly: true) }
        }
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

        let eventSubscriptionId = event["subscriptionId"] as? String
        return if let subscriptionId, let eventSubscriptionId {
            eventSubscriptionId != subscriptionId
        } else {
            false
        }
    }

    private func handleAgentUpdated(_ data: [String: Any]) {
        sessionMetadataGeneration += 1
        if let pendingId = data["pendingQuestionsMessageId"] as? String {
            pendingQuestionsMessageId = pendingId
        }
        if let dismissedId = data["dismissedQuestionsMessageId"] as? String {
            dismissedQuestionsMessageId = dismissedId
        }
        if let seenId = data["lastSeenMessageId"] as? String {
            lastSeenMessageId = seenId
        }
        reconcilePendingQuestionRecovery()
    }

    private func handleQueueUpdated(_ data: [String: Any]) {
        if let decoded = ConversationCommands.decodeQueueSnapshot(
            data["queue"],
            source: "agent:queue:updated"
        ) {
            queuedMessages = decoded
            return
        }
        if let agentId {
            Task { await fetchQueue(agentId: agentId) }
        }
    }

    private func handleQueueProcessing(_ data: [String: Any]) {
        if let messageId = data["messageId"] as? String {
            queuedMessages.removeAll { $0.id == messageId }
        } else if let agentId {
            Task { await fetchQueue(agentId: agentId) }
        }
    }

    private func handleUserMessageSent(_ data: [String: Any]) {
        guard let messageId = data["messageId"] as? String,
              let content = data["content"] as? String else { return }
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
