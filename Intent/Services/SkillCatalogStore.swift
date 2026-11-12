import Foundation
import Observation

@MainActor
@Observable final class SkillCatalogStore {
    private(set) var skills: [SkillInfo] = []
    private(set) var loadPhase = LoadPhase.idle
    var isLoading: Bool { loadPhase.isLoading }
    var errorMessage: String? { loadPhase.failureMessage }

    @ObservationIgnored private var loadIdentity = UUID()

    /// Skills do not change during an app session, so a successful catalog is reused per
    /// agent and connection. Failures are not cached; the next opening retries.
    private struct CacheKey: Hashable {
        let workspaceId: String
        let agentId: String
    }

    private struct CachedCatalog {
        weak var connection: AnyObject?
        let skills: [SkillInfo]
    }

    private static var cache: [CacheKey: CachedCatalog] = [:]

    /// Offline, the visible catalog is cleared so keyboard acceptance cannot insert a hidden
    /// suggestion; the session cache survives and repopulates the picker on reconnect.
    func refresh(workspaceId: String, agentId: String, connection: any ConnectionManagerRouting) async {
        guard connection.connectionState == .connected else {
            reset()
            return
        }
        await load(workspaceId: workspaceId, agentId: agentId, connection: connection)
    }

    func load(workspaceId: String, agentId: String, connection: any ConnectionManagerRouting) async {
        guard !Task.isCancelled else { return }
        let key = CacheKey(workspaceId: workspaceId, agentId: agentId)
        if let cached = Self.cache[key], cached.connection === connection {
            loadIdentity = UUID()
            skills = cached.skills
            loadPhase = .loaded(Date())
            return
        }
        reset()
        let identity = loadIdentity
        loadPhase = .loading(lastLoadedAt: nil)
        defer {
            if identity == loadIdentity { loadPhase = loadPhase.settled() }
        }
        do {
            let response = try await connection.request("skill.list", params: ["workspaceId": workspaceId])
            guard identity == loadIdentity, !Task.isCancelled else { return }
            guard let items = response as? [Any] else { throw CocoaError(.coderReadCorrupt) }
            var locations: Set<String> = []
            skills = items.compactMap { item -> SkillInfo? in
                guard let wire = item as? [String: Any], let skill = SkillInfo(wire: wire),
                      locations.insert(skill.location).inserted else { return nil }
                return skill
            }
            .sorted { lhs, rhs in
                let left = lhs.name.lowercased()
                let right = rhs.name.lowercased()
                if left != right { return left < right }
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return lhs.location < rhs.location
            }
            Self.cache[key] = CachedCatalog(connection: connection, skills: skills)
            loadPhase = .loaded(Date())
        } catch {
            guard identity == loadIdentity, !Task.isCancelled, !(error is CancellationError) else { return }
            loadPhase = .failed("Skills could not be loaded. Try again.")
        }
    }

    /// Clears suggestions and invalidates replies when the composer leaves its workspace.
    func reset() {
        loadIdentity = UUID()
        skills = []
        loadPhase = .idle
    }
}
