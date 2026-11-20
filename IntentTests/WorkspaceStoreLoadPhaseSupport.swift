import Foundation
@testable import Intent

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
