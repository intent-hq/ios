import Foundation
@testable import Intent

/// Test seams for coordinator fixtures that toggle "a read is running" and
/// "a list was published" independently, as the store's single phase does.
@MainActor
extension WorkspaceStore {
    func setLoading(_ loading: Bool) {
        let stamp = lastUpdated
        loadPhase = loading ? .loading(lastLoadedAt: stamp) : stamp.map { .loaded($0) } ?? .idle
    }

    func setLastUpdated(_ date: Date?) {
        loadPhase = isLoading ? .loading(lastLoadedAt: date) : date.map { .loaded($0) } ?? .idle
    }
}
