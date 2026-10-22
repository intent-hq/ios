import Foundation
import Observation

@MainActor
@Observable final class SkillCatalogStore {
    private(set) var skills: [SkillInfo] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored private var loadIdentity = UUID()

    /// Each popup opening refreshes the catalog, including after an earlier failure.
    func load(workspaceId: String, connection: any ConnectionManagerRouting) async {
        guard !Task.isCancelled else { return }
        reset()
        let identity = loadIdentity
        isLoading = true
        defer {
            if identity == loadIdentity { isLoading = false }
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
        } catch {
            guard identity == loadIdentity, !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = "Skills could not be loaded. Try again."
        }
    }

    /// Clears suggestions and invalidates replies when the composer leaves its workspace.
    func reset() {
        loadIdentity = UUID()
        skills = []
        isLoading = false
        errorMessage = nil
    }
}
