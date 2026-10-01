import Foundation
import Observation

/// Agent conversations opened in this install, most recent first, across
/// every saved connection. One instance serves all windows.
@MainActor
@Observable
final class AgentHistoryStore {
    static let shared = AgentHistoryStore(persistence: .shared)

    private(set) var entries: [AgentHistoryEntry]
    @ObservationIgnored private let persistence: PersistenceManager

    init(persistence: PersistenceManager) {
        self.persistence = persistence
        entries = persistence.loadAgentHistory()
    }

    func record(_ visit: AgentHistoryEntry) {
        entries = AgentHistory.recording(visit, in: entries)
        persistence.saveAgentHistory(entries)
    }

    func clear() {
        entries = []
        persistence.saveAgentHistory(entries)
    }
}
