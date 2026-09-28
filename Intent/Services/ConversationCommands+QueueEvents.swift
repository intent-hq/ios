import Foundation

extension ConversationCommands {
    enum QueueMutation {
        case append(QueuedMessage)
        case edit(String, content: String, fallback: QueuedMessage?)
        case remove(String)

        func apply(to queue: inout [QueuedMessage]) {
            switch self {
            case .append(let message):
                if let index = queue.firstIndex(where: { $0.id == message.id }) { queue[index] = message } else { queue.append(message) }
            case let .edit(id, content, fallback):
                if let index = queue.firstIndex(where: { $0.id == id }) {
                    queue[index].content = content
                } else if var message = fallback {
                    message.content = content
                    queue.append(message)
                }
            case .remove(let id):
                queue.removeAll { $0.id == id }
            }
        }
    }

    /// Only buffered workspace events need a journal. Its lifetime belongs to
    /// the shared conversation owner, and ends when those events fold or cancel.
    final class QueueMutationHistory {
        private(set) var generation = 0
        private var deferring = false
        private var confirmed: [(sequence: Int, mutation: QueueMutation)] = []

        func beginDeferring() { deferring = true }

        func record(_ mutation: QueueMutation, at sequence: Int) {
            if deferring { confirmed.append((sequence, mutation)) }
        }

        func applying(to queue: [QueuedMessage], after sequence: Int) -> [QueuedMessage] {
            var queue = queue
            for entry in confirmed where entry.sequence > sequence { entry.mutation.apply(to: &queue) }
            return queue
        }

        func finish() {
            deferring = false
            confirmed.removeAll()
        }

        func cancel() {
            generation &+= 1
            finish()
        }
    }

    func confirmQueueMutation(_ mutation: QueueMutation, generation: Int) {
        // A completed ACK belongs to surviving owners even if its caller was
        // cancelled meanwhile. Final release/reset invalidates the generation.
        guard generation == queueMutations.generation else { return }
        let sequence = agentDetails.nextStateSequence()
        queueMutations.record(mutation, at: sequence)
        for read in queueReads.values where read.revision == queueRevision {
            read.revision &+= 1
            read.mutations.append((sequence, mutation))
        }
        mutation.apply(to: &queuedMessages)
    }

    final class QueueRead {
        var revision: Int
        let sequence: Int
        var replayedEarlierEvent = false
        var mutations: [(sequence: Int, mutation: QueueMutation)] = []

        init(revision: Int, sequence: Int) {
            self.revision = revision
            self.sequence = sequence
        }

        func applying(to queue: [QueuedMessage]) -> [QueuedMessage] {
            var queue = queue
            // Buffered processing can be applied after a later local ACK.
            // Receipt order, not application order, determines the final rows.
            for entry in mutations.sorted(by: { $0.sequence < $1.sequence }) { entry.mutation.apply(to: &queue) }
            return queue
        }
    }

    func applyQueueEvent(_ queue: [QueuedMessage], receivedAt: Int) {
        // Delayed workspace validation can replay an event during a read that
        // actually started later. Let a complete reply supersede that event.
        for read in queueReads.values where receivedAt < read.sequence && read.revision == queueRevision {
            read.revision &+= 1
            read.replayedEarlierEvent = true
        }
        queuedMessages = queueMutations.applying(to: queue, after: receivedAt)
        onQueueSnapshot?(queuedMessages)
    }

    /// Only processing received after a read started removes rows from its seed.
    /// Untouched rows survive without extending the bounded reconciliation loop.
    func removeProcessingMessage(_ messageId: String, receivedAt: Int? = nil) {
        let receivedAt = receivedAt ?? agentDetails.nextStateSequence()
        for read in queueReads.values {
            if read.revision == queueRevision { read.revision &+= 1 }
            if receivedAt > read.sequence { read.mutations.append((receivedAt, .remove(messageId))) } else { read.replayedEarlierEvent = true }
        }
        let remaining = queuedMessages.filter { $0.id != messageId }
        queuedMessages = queueMutations.applying(to: remaining, after: receivedAt)
    }
}
