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
        queueReadPending = true
        guard let agentId else { return }
        let activation = eventRegistrationGeneration
        Task { [weak self] in
            guard let self, ownsStreamingRegistration(activation) else { return }
            await fetchQueue(agentId: agentId)
        }
    }

    func fetchQueue(agentId: String) async {
        guard !Task.isCancelled else { return }
        if let queueReadTask { await queueReadTask.value; return }
        let generation = bootstrapGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            repeat {
                guard !Task.isCancelled, generation == bootstrapGeneration else { return }
                queueReadPending = false
                do { try await commands.fetchQueue(agentId: agentId) } catch {
                    AppLog.conversation.error("[ConversationStore] Failed to fetch queue: \(error)")
                }
            } while queueReadPending
        }
        queueReadTask = task
        await task.value
        if generation == bootstrapGeneration { queueReadTask = nil }
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

    func getModels(agentId: String) async throws -> [[String: Any]] {
        try await commands.getModels(agentId: agentId)
    }

    func setModel(agentId: String, modelId: String, workspaceId: String) async throws {
        try await commands.setModel(
            agentId: agentId,
            modelId: modelId,
            workspaceId: workspaceId
        )
    }

    // MARK: - Agent subscriptions

    func invalidateSubscriptions() {
        subscriptionRevision &+= 1
        guard let agentId, let workspaceId else { return }
        let activation = eventRegistrationGeneration
        Task { [weak self] in
            guard let self, ownsStreamingRegistration(activation) else { return }
            await fetchSubscriptions(agentId: agentId, workspaceId: workspaceId)
        }
    }

    func fetchSubscriptions(agentId: String, workspaceId: String) async {
        guard !Task.isCancelled else { return }
        if let subscriptionReadTask { await subscriptionReadTask.value; return }
        let generation = bootstrapGeneration
        let task = Task { [weak self] in
            guard let self else { return }
            var revision: Int
            repeat {
                guard !Task.isCancelled, generation == bootstrapGeneration else { return }
                revision = subscriptionRevision
                await watchedAgentCoordinator.fetchSubscriptions(agentId: agentId, workspaceId: workspaceId) {
                    generation == self.bootstrapGeneration && revision == self.subscriptionRevision
                }
            } while revision != subscriptionRevision
        }
        subscriptionReadTask = task
        await task.value
        if generation == bootstrapGeneration { subscriptionReadTask = nil }
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
