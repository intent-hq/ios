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
        let messageId: String
        if let failed = lastFailedSend, failed.content == content {
            messageId = failed.messageId
            messages.removeAll { $0.id == failed.messageId }
        } else {
            messageId = UUID().uuidString
        }
        let userMessage = ConversationMessage(
            id: messageId,
            role: .user,
            contentBlocks: [ContentBlock(id: "\(messageId):0", type: .text, text: content)],
            metadata: messageMetadata.optimisticFields,
            metadataWasProvided: messageMetadata.wasProvided
        )
        withAnimation(.spring(
            response: Constants.Conversation.Sending.messageAppendSpringResponse,
            dampingFraction: Constants.Conversation.Sending.messageAppendSpringDamping
        )) {
            messages.append(userMessage)
        }

        withAnimation(.easeOut(
            duration: Constants.Conversation.Sending.stateTransitionAnimationDuration
        )) {
            isStreaming = true
        }

        let queued: Bool
        do {
            queued = try await commands.sendMessage(.init(
                agentId: agentId,
                content: content,
                workspaceId: workspaceId,
                messageId: messageId,
                imagePayload: imagePayload,
                filePayload: filePayload,
                messageMetadata: messageMetadata
            ))
        } catch {
            lastFailedSend = (messageId: messageId, content: content)
            throw error
        }

        lastFailedSend = nil

        if queued {
            isStreaming = false
            withAnimation(.easeOut(
                duration: Constants.Conversation.Sending.stateTransitionAnimationDuration
            )) {
                messages.removeAll { $0.id == userMessage.id }
            }
        }
    }

    func rollbackFailedSend() {
        guard let failed = lastFailedSend else { return }
        withAnimation(.easeOut(
            duration: Constants.Conversation.Sending.stateTransitionAnimationDuration
        )) {
            messages.removeAll { $0.id == failed.messageId }
            isStreaming = false
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

    func fetchQueue(agentId: String) async {
        do {
            try await commands.fetchQueue(agentId: agentId)
        } catch {
            AppLog.conversation.error("[ConversationStore] Failed to fetch queue: \(error)")
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

    func fetchSubscriptions(agentId: String, workspaceId: String) async {
        await watchedAgentCoordinator.fetchSubscriptions(
            agentId: agentId,
            workspaceId: workspaceId
        )
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
        liveTranscript.reset()
        commands.reset()
        watchedAgentCoordinator.reset()
        bindAgent(nil)
        workspaceId = nil
        subscriptionId = nil
        currentStreamId = nil
        isSubscribing = false
        streamEventBuffer.removeAll()
        lastFailedSend = nil
        agentNotFound = false
        clearPendingQuestionRecovery()
    }
}
