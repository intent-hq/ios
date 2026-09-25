import Foundation
import SwiftUI
import UIKit

extension ConversationStore {
    /// Called before attachment placement suspends. New sends always receive a
    /// new identity, even when their text happens to match an older failure.
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
        do {
            let acceptance = try await commands.sendMessage(attempt.request)
            guard let current = sendAttempts.first(where: { $0.id == messageId }) else { throw CancellationError() }
            if current.status != .accepted, let seed = acceptance.queueSeed,
               !queuedMessages.contains(where: { $0.id == seed.id }) {
                queuedMessages.append(seed)
            }
            confirmSendAttempt(
                messageId,
                status: acceptance.queued ? .queued : .accepted,
                confirmedMessageId: acceptance.messageId
            )
        } catch {
            sendThinkingMessageIds.remove(messageId)
            guard let current = sendAttempts.firstIndex(where: { $0.id == messageId }) else { throw error }
            // An authoritative echo may beat a timeout/error response. Never
            // demote that positive acceptance evidence back to uncertainty.
            if sendAttempts[current].status.isConfirmed { return }
            // Only app-owned pre-dispatch provenance establishes non-delivery.
            // A remote RPC can reuse WebSocket/-4; its code alone is not proof.
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

    /// Positive rows only: missing pages, malformed reads, projected queues and
    /// absent ids are never evidence that a mutation did not happen.
    func reconcileSendAttempts(messages incoming: [ConversationMessage]) {
        for message in incoming where message.role == .user && message.hasReportedContentBlocks {
            // AgentMessage reads lift this out of row metadata. A nested legacy
            // copy must not override the canonical top-level correlation.
            let appId = message.appMessageId ?? message.metadata["userAppMessageId"]?.stringValue
            guard let attemptId = sendAttemptId(rowId: message.id, appMessageId: appId) else { continue }
            confirmSendAttempt(attemptId, status: .accepted, confirmedMessageId: message.id)
            // RPC acceptance is terminal for status, not transcript identity.
            // Only authoritative rows may refine an already accepted association;
            // late RPC/queue results still stop at confirmSendAttempt's guard.
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
            // Present correlation is exclusive, including unknown IDs. Only
            // its absence permits direct or previously confirmed row identity.
            if let appMessageId { return attempt.id == appMessageId }
            return attempt.id == rowId || attempt.confirmedMessageId == rowId
        }
        // Count attempts, not matching fields: two identities on one attempt
        // are fine, but a row naming different attempts settles none.
        guard matches.count == 1 else { return nil }
        return matches.first?.id
    }

    /// Read-only and explicitly user-triggered; never resends a mutation. It can
    /// confirm a matching row, but cannot turn an absent row into a safe retry.
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
        // fetchQueue reconciles only the response rows, not cached/optimistic data.
        try? await commands.fetchQueue(agentId: attempt.agentId)
    }
}
