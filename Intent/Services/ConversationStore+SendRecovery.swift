import Foundation
import SwiftUI
import UIKit

extension ConversationStore {
    func beginSendAttempt(
        agentId: String,
        content: String,
        workspaceId: String,
        images: [UIImage] = [],
        files: [PendingFile] = [],
        fileAccess: ConversationSendFileAccess? = nil,
        messageMetadata: MessageSendMetadata = .none
    ) -> String {
        let attempt = ConversationSendAttempt(
            id: UUID().uuidString,
            agentId: agentId,
            workspaceId: workspaceId,
            content: content,
            images: images,
            files: files,
            messageMetadata: messageMetadata,
            fileAccess: fileAccess
        )
        sendAttempts.append(attempt)
        return attempt.id
    }

    func prepareSendAttempt(
        _ messageId: String,
        imagePayload: OutgoingImagePayload,
        filePayload: OutgoingFilePayload,
        complete: Bool = true
    ) {
        guard let index = sendAttempts.firstIndex(where: { $0.id == messageId }),
              sendAttempts[index].status == .preparing else { return }
        sendAttempts[index].imagePayload = imagePayload
        sendAttempts[index].filePayload = filePayload
        sendAttempts[index].isPrepared = complete
    }

    func failSendPreparation(_ messageId: String) {
        guard let index = sendAttempts.firstIndex(where: { $0.id == messageId }),
              sendAttempts[index].status == .preparing else { return }
        sendAttempts[index].status = .notSent
    }

    func sendPreparedAttempt(_ messageId: String) async throws {
        guard let index = sendAttempts.firstIndex(where: { $0.id == messageId }),
              sendAttempts[index].isPrepared,
              sendAttempts[index].status == .preparing || sendAttempts[index].canRetry else {
            throw ConversationSendError.replayUnavailable
        }
        let attempt = sendAttempts[index]
        if Task.isCancelled {
            sendAttempts[index].status = .notSent
            throw CancellationError()
        }
        sendAttempts[index].status = .sending
        appendOptimisticSend(attempt)
        sendThinkingMessageIds.insert(messageId)
        let queueGeneration = commands.queueMutations.generation
        do {
            let acceptance = try await commands.sendMessage(attempt.request)
            guard let current = sendAttempts.first(where: { $0.id == messageId }) else { throw CancellationError() }
            if current.status != .accepted, let seed = acceptance.queueSeed,
               !queuedMessages.contains(where: { $0.id == seed.id }) {
                commands.confirmQueueMutation(.append(seed), generation: queueGeneration)
            }
            confirmSendAttempt(
                messageId,
                status: acceptance.queued ? .queued : .accepted,
                confirmedMessageId: acceptance.messageId
            )
        } catch {
            sendThinkingMessageIds.remove(messageId)
            guard let current = sendAttempts.firstIndex(where: { $0.id == messageId }) else { throw error }
            if sendAttempts[current].status.isConfirmed { return }
            if error is OutgoingImagePayload.RequestError {
                sendAttempts[current].status = .notSent
                sendAttempts[current].isPrepared = false
                throw error
            }
            let failure = DiagnosticErrorOwnership.failure(for: error)
            sendAttempts[current].status = failure.origin == .localRequest && failure.classification == .notConnected
                ? .notSent : .unconfirmed
            throw error
        }
    }

    private func appendOptimisticSend(_ attempt: ConversationSendAttempt) {
        messages.removeAll { $0.id == attempt.id }
        let message = ConversationMessage(
            id: attempt.id,
            role: .user,
            contentBlocks: [ContentBlock(id: "\(attempt.id):0", type: .text, text: attempt.content)],
            metadata: attempt.messageMetadata.optimisticFields,
            metadataWasProvided: attempt.messageMetadata.wasProvided
        )
        withAnimation(.spring(
            response: Constants.Conversation.Sending.messageAppendSpringResponse,
            dampingFraction: Constants.Conversation.Sending.messageAppendSpringDamping
        )) {
            messages.append(message)
        }
    }

    func confirmSendAttempt(
        _ messageId: String,
        status: ConversationSendAttempt.Status,
        confirmedMessageId: String?
    ) {
        guard let index = sendAttempts.firstIndex(where: { $0.id == messageId }),
              sendAttempts[index].status != .accepted else { return }
        sendAttempts[index].status = status
        sendAttempts[index].confirmedMessageId = confirmedMessageId
        sendAttempts[index].releaseConfirmedResources()
        if status == .queued {
            sendThinkingMessageIds.remove(messageId)
            messages.removeAll { $0.id == messageId }
        } else if let confirmedMessageId, confirmedMessageId != messageId {
            messages.removeAll { $0.id == messageId }
        }
    }

    func reconcileSendAttempts(messages incoming: [ConversationMessage]) {
        for message in incoming where message.role == .user && message.hasReportedContentBlocks {
            let appId = message.appMessageId ?? message.metadata["userAppMessageId"]?.stringValue
            guard let attemptId = sendAttemptId(rowId: message.id, appMessageId: appId) else { continue }
            confirmSendAttempt(attemptId, status: .accepted, confirmedMessageId: message.id)
            if let index = sendAttempts.firstIndex(where: { $0.id == attemptId }) {
                sendAttempts[index].confirmedMessageId = message.id
            }
            if message.id != attemptId {
                messages.removeAll { $0.id == attemptId }
            }
        }
    }

    func reconcileSendAttempts(queue: [QueuedMessage]) {
        for message in queue {
            let appId = message.messageMetadata["userAppMessageId"]?.value as? String
            guard let attemptId = sendAttemptId(rowId: message.id, appMessageId: appId) else { continue }
            confirmSendAttempt(attemptId, status: .queued, confirmedMessageId: message.id)
        }
    }

    private func sendAttemptId(rowId: String, appMessageId: String?) -> String? {
        let matches = sendAttempts.filter { attempt in
            guard agentId == nil || attempt.agentId == agentId else { return false }
            if let appMessageId { return attempt.id == appMessageId }
            return attempt.id == rowId || attempt.confirmedMessageId == rowId
        }
        guard matches.count == 1 else { return nil }
        return matches.first?.id
    }

    func inspectSendAttempt(_ messageId: String) async {
        guard let index = sendAttempts.firstIndex(where: { $0.id == messageId }),
              sendAttempts[index].status == .unconfirmed || sendAttempts[index].status == .queued,
              !sendAttempts[index].isCheckingStatus else { return }
        let attempt = sendAttempts[index]
        sendAttempts[index].isCheckingStatus = true
        defer {
            if let current = sendAttempts.firstIndex(where: { $0.id == messageId }) {
                sendAttempts[current].isCheckingStatus = false
            }
        }
        if let message = try? await commands.fetchMessage(
            agentId: attempt.agentId,
            messageId: attempt.confirmedMessageId ?? attempt.id,
            workspaceId: attempt.workspaceId
        ), sendAttempts.contains(where: { $0.id == messageId }) {
            reconcileSendAttempts(messages: [message])
        }
        guard sendAttempts.contains(where: { $0.id == messageId }), !Task.isCancelled else { return }
        try? await commands.fetchQueue(agentId: attempt.agentId)
    }
}
