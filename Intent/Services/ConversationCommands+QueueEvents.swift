import Foundation

extension ConversationCommands {
    final class QueueRead {
        var revision: Int
        let sequence: Int
        var replayedEarlierEvent = false
        var removed: Set<String> = []

        init(revision: Int, sequence: Int) {
            self.revision = revision
            self.sequence = sequence
        }
    }

    func applyQueueEvent(_ queue: [QueuedMessage], receivedAt: Int) {
        // Delayed workspace validation can replay an event during a read that
        // actually started later. Let a complete reply supersede that event.
        for read in queueReads.values where receivedAt < read.sequence && read.revision == queueRevision {
            read.revision &+= 1
            read.replayedEarlierEvent = true
        }
        queuedMessages = queue
        onQueueSnapshot?(queue)
    }

    /// Only processing received after a read started removes rows from its seed.
    /// Untouched rows survive without extending the bounded reconciliation loop.
    func removeProcessingMessage(_ messageId: String, receivedAt: Int? = nil) {
        let receivedAt = receivedAt ?? agentDetails.nextStateSequence()
        for read in queueReads.values {
            if read.revision == queueRevision { read.revision &+= 1 }
            if receivedAt > read.sequence { read.removed.insert(messageId) } else { read.replayedEarlierEvent = true }
        }
        queuedMessages.removeAll { $0.id == messageId }
    }
}
