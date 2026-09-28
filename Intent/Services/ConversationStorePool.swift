import Foundation

/// Backend-local identity for an active conversation. Models own leases and
/// presentation state; only the final lease releases the shared live channel.
@MainActor
final class ConversationStorePool {
    private struct Entry {
        weak var store: ConversationStore?
    }

    private let connection: any ConnectionManagerRouting
    private let details: AgentDetailStore
    private var entries: [String: Entry] = [:]

    init(connection: any ConnectionManagerRouting, details: AgentDetailStore) {
        self.connection = connection
        self.details = details
    }

    func store(agentId: String) -> ConversationStore {
        entries = entries.filter { $0.value.store != nil }
        if let store = entries[agentId]?.store { return store }
        let store = ConversationStore(connectionManager: connection, agentDetails: details)
        entries[agentId] = Entry(store: store)
        return store
    }

    func reset() {
        for entry in entries.values { entry.store?.reset() }
        entries.removeAll()
    }
}
