import Foundation
import SwiftUI

extension ConversationStore {
    // MARK: - Send message

    func sendMessage(
        agentId: String,
        content: String,
        workspaceId: String,
        imagePayload: OutgoingImagePayload = .none,
        filePayload: OutgoingFilePayload = .none,
        messageMetadata: MessageSendMetadata = .none
    ) async throws {
        let messageId = beginSendAttempt(
            agentId: agentId,
            content: content,
            workspaceId: workspaceId,
            messageMetadata: messageMetadata
        )
        prepareSendAttempt(messageId, imagePayload: imagePayload, filePayload: filePayload)
        try await sendPreparedAttempt(messageId)
    }

    func rollbackFailedSend() {
        guard let failed = lastFailedSend else { return }
        withAnimation(.easeOut(
            duration: Constants.Conversation.Sending.stateTransitionAnimationDuration
        )) {
            messages.removeAll { $0.id == failed.id }
            sendThinkingMessageIds.remove(failed.id)
        }
    }

    // MARK: - Questions and seen marker

    func dismissQuestions(agentId: String, messageId: String, workspaceId: String) async throws {
        try await commands.dismissQuestions(
            agentId: agentId,
            messageId: messageId,
            workspaceId: workspaceId
        )
    }

    func markSeen(agentId: String, workspaceId: String) async {
        await commands.markSeen(
            agentId: agentId,
            workspaceId: workspaceId,
            messages: messages
        )
    }

    // MARK: - Queue commands

    func queueMessage(
        agentId: String,
        content: String,
        imagePayload: OutgoingImagePayload = .none,
        filePayload: OutgoingFilePayload = .none
    ) async throws {
        try await commands.queueMessage(
            agentId: agentId,
            content: content,
            imagePayload: imagePayload,
            filePayload: filePayload
        )
    }

    func stopStreaming(agentId: String) async {
        do {
            try await commands.stop(agentId: agentId)
        } catch {
            AppLog.conversation.error("[ConversationStore] Failed to stop streaming: \(error)")
        }
    }

    func refreshQueue() {
        commands.invalidateQueueReads()
        guard queueReads.invalidate() else { return }
        guard let agentId else {
            queueReads.settleScheduled()
            return
        }
        let activation = eventRegistrationGeneration
        let epoch = bootstrapGeneration
        Task { [weak self] in
            guard let self, bootstrapGeneration == epoch else { return }
            if ownsStreamingRegistration(activation) { await fetchQueue(agentId: agentId) }
            if bootstrapGeneration == epoch { queueReads.settleScheduled() }
        }
    }

    func fetchQueue(agentId: String) async {
        let generation = bootstrapGeneration
        await queueReads.run { [weak self] in
            generation == self?.bootstrapGeneration
        } pass: { [weak self] _ in
            guard let self else { return }
            do { try await commands.fetchQueue(agentId: agentId) } catch {
                AppLog.conversation.error("[ConversationStore] Failed to fetch queue: \(error)")
            }
        }
    }

    func editQueuedMessage(agentId: String, messageId: String, content: String) async throws {
        try await commands.editQueuedMessage(
            agentId: agentId,
            messageId: messageId,
            content: content
        )
    }

    func sendQueuedMessageNow(agentId: String, messageId: String, workspaceId: String) async throws {
        try await commands.sendQueuedMessageNow(
            agentId: agentId,
            messageId: messageId,
            workspaceId: workspaceId
        )
    }

    func removeQueuedMessage(agentId: String, messageId: String) async throws {
        try await commands.removeQueuedMessage(agentId: agentId, messageId: messageId)
    }

    // MARK: - Models

    func setModel(agentId: String, modelId: String, workspaceId: String, providerId: String? = nil) async throws {
        try await commands.setModel(
            agentId: agentId,
            modelId: modelId,
            workspaceId: workspaceId,
            providerId: providerId
        )
    }

    func setReasoningEffort(agentId: String, workspaceId: String, effort: String?) async throws {
        try await commands.setReasoningEffort(agentId: agentId, workspaceId: workspaceId, effort: effort)
    }

    // MARK: - Agent subscriptions

    func invalidateSubscriptions() {
        guard subscriptionReads.invalidate() else { return }
        guard let agentId, let workspaceId = workspaceId ?? bootstrapWorkspaceHint else {
            subscriptionReads.settleScheduled()
            return
        }
        let activation = eventRegistrationGeneration
        let epoch = bootstrapGeneration
        Task { [weak self] in
            guard let self, bootstrapGeneration == epoch else { return }
            if ownsStreamingRegistration(activation) { await fetchSubscriptions(agentId: agentId, workspaceId: workspaceId) }
            if bootstrapGeneration == epoch { subscriptionReads.settleScheduled() }
        }
    }

    func fetchSubscriptions(agentId: String, workspaceId: String) async {
        let generation = bootstrapGeneration
        await subscriptionReads.run { [weak self] in
            generation == self?.bootstrapGeneration
        } pass: { [weak self] revision in
            guard let self else { return }
            await watchedAgentCoordinator.fetchSubscriptions(
                agentId: agentId,
                workspaceId: self.workspaceId ?? workspaceId,
                awaitAuthority: { await self.awaitWorkspaceAuthority() },
                isCurrent: { generation == self.bootstrapGeneration && revision == self.subscriptionReads.revision }
            )
        }
    }

    func cancelSubscriptions(agentId: String, workspaceId: String) async {
        await watchedAgentCoordinator.cancelSubscriptions(
            agentId: agentId,
            workspaceId: workspaceId
        )
    }

    func stopWatchedAgents(agentIds: [String], parentAgentId: String, workspaceId: String) async {
        await watchedAgentCoordinator.stopAgents(
            agentIds: agentIds,
            parentAgentId: parentAgentId,
            workspaceId: workspaceId
        )
    }

    // MARK: - Cleanup

    func reset() {
        deactivateStreaming()
        liveTranscript.reset()
        commands.reset()
        watchedAgentCoordinator.reset()
        bindAgent(nil)
        workspaceId = nil
        sendAttempts.removeAll()
        sendThinkingMessageIds.removeAll()
        agentNotFound = false
        clearPendingQuestionRecovery()
    }
}
