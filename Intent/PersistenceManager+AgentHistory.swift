import Foundation

extension PersistenceManager {
    // MARK: - Agent history (global, across connections)

    private static let agentHistoryKey = "agentHistory"

    func loadAgentHistory() -> [AgentHistoryEntry] {
        guard let data = defaults.data(forKey: Self.agentHistoryKey) else { return [] }
        return (try? JSONDecoder().decode([AgentHistoryEntry].self, from: data)) ?? []
    }

    func saveAgentHistory(_ entries: [AgentHistoryEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.agentHistoryKey)
    }
}
