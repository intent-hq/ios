import Foundation
import UIKit

/// Session-local recovery, independent of the replaceable transcript. The
/// original identity never changes; selections and placed references remain
/// owned until delivery is confirmed. Not a durable outbox or an idempotency key.
struct ConversationSendAttempt: Identifiable {
    enum Status: Equatable {
        case preparing
        case sending
        case accepted
        case queued
        case notSent
        case unconfirmed

        var needsRecovery: Bool { self == .notSent || self == .unconfirmed }
        var isConfirmed: Bool { self == .accepted || self == .queued }
    }

    let id: String
    let agentId: String
    let workspaceId: String
    let content: String
    private(set) var images: [UIImage]
    private(set) var files: [PendingFile]
    let messageMetadata: MessageSendMetadata
    var fileAccess: ConversationSendFileAccess?
    var imagePayload: OutgoingImagePayload = .none
    var filePayload: OutgoingFilePayload = .none
    var isPrepared = false
    var status: Status = .preparing
    var isCheckingStatus = false
    var confirmedMessageId: String?

    /// Only a locally proven pre-dispatch failure may be retried. The daemon
    /// auto-queues duplicate ordinary sends rather than deduplicating them.
    var canRetry: Bool { status == .notSent && isPrepared }

    mutating func releaseConfirmedResources() {
        guard status.isConfirmed else { return }
        images = []
        files = []
        imagePayload = .none
        filePayload = .none
        fileAccess = nil
    }

    var request: ConversationCommands.SendRequest {
        .init(
            agentId: agentId,
            content: content,
            workspaceId: workspaceId,
            messageId: id,
            imagePayload: imagePayload,
            filePayload: filePayload,
            messageMetadata: messageMetadata
        )
    }
}

/// Extra leases owned by an attempt, not by the changing composer selection.
final class ConversationSendFileAccess {
    private let urls: [URL]
    private let stopAccess: @Sendable (URL) -> Void

    init(urls: [URL], stopAccess: @escaping @Sendable (URL) -> Void) {
        self.urls = urls
        self.stopAccess = stopAccess
    }

    deinit {
        for url in urls { stopAccess(url) }
    }
}

extension ConversationCommands {
    struct SendRequest {
        let agentId: String
        let content: String
        let workspaceId: String
        let messageId: String
        let imagePayload: OutgoingImagePayload
        let filePayload: OutgoingFilePayload
        let messageMetadata: MessageSendMetadata
    }

    struct SendAcceptance {
        let queued: Bool
        let messageId: String?
        var queueSeed: QueuedMessage?
    }
}

enum ConversationSendError: Error {
    case invalidAcknowledgement
    case replayUnavailable
}
