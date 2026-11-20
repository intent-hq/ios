import Foundation

@MainActor
final class ConversationStorePool {
    static let retainedConversationLimit = 10

    private struct Entry {
        weak var store: ConversationStore?
    }

    private let connection: any ConnectionManagerRouting
    private let details: AgentDetailStore
    private var entries: [String: Entry] = [:]
    private var recent = RecentRetention<String, ConversationStore>(capacity: retainedConversationLimit)

    init(connection: any ConnectionManagerRouting, details: AgentDetailStore) {
        self.connection = connection
        self.details = details
    }

    func store(agentId: String) -> ConversationStore {
        entries = entries.filter { $0.value.store != nil }
        let store = entries[agentId]?.store
            ?? ConversationStore(connectionManager: connection, agentDetails: details)
        entries[agentId] = Entry(store: store)
        recent.touch(agentId, value: store)
        return store
    }

    func reset() {
        for entry in entries.values { entry.store?.reset() }
        entries.removeAll()
        recent.removeAll()
    }
}
