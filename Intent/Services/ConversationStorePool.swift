import Foundation

/// Backend-local identity for an active conversation. Models own leases and
/// presentation state; only the final lease releases the shared live channel.
@MainActor
final class ConversationStorePool {
    private struct StoreKey: Hashable {
        let agentId: String
        let workspaceId: String
    }
    private struct Entry {
        weak var store: ConversationStore?
    }

    private let connection: any ConnectionManagerRouting
    private let details: AgentDetailStore
    private var entries: [StoreKey: Entry] = [:]

    init(connection: any ConnectionManagerRouting, details: AgentDetailStore) {
        self.connection = connection
        self.details = details
    }

    func store(agentId: String, workspaceId: String) -> ConversationStore {
        entries = entries.filter { $0.value.store != nil }
        let key = StoreKey(agentId: agentId, workspaceId: workspaceId)
        if let store = entries[key]?.store { return store }
        let store = ConversationStore(connectionManager: connection, agentDetails: details)
        entries[key] = Entry(store: store)
        return store
    }

    func reset() {
        for entry in entries.values { entry.store?.reset() }
        entries.removeAll()
    }
}
