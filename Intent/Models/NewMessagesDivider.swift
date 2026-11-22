import CoreGraphics
import Foundation

enum NewMessagesDivider {
    static func resolveAnchor(
        messageIds: [String],
        lastSeenMessageId: String?,
        userMessageIds: Set<String> = []
    ) -> String? {
        guard let marker = lastSeenMessageId, !marker.isEmpty, !messageIds.isEmpty else {
            return nil
        }
        guard let markerIndex = messageIds.firstIndex(of: marker) else { return nil }
        if markerIndex == messageIds.count - 1 { return nil }
        if userMessageIds.contains(marker) { return nil }
        return marker
    }

    static func resolveLatchedAnchor(
        messageIds: [String],
        latchedAnchorId: String?
    ) -> String? {
        guard let anchor = latchedAnchorId, !anchor.isEmpty else { return nil }
        return messageIds.contains(anchor) ? anchor : nil
    }

    static func followDisabledAfterEntryScroll(
        distanceToBottom: CGFloat?,
        atBottomThreshold: CGFloat = Constants.Conversation.Transcript.atBottomThreshold
    ) -> Bool {
        guard let distanceToBottom else { return true }
        return distanceToBottom > atBottomThreshold
    }
}

enum NewMessagesDividerLatch: Equatable {
    case latched(anchorId: String?)
    case unlatched

    var anchorId: String? {
        if case .latched(let anchorId) = self { return anchorId }
        return nil
    }
}
