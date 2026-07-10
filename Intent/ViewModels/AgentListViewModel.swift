import Combine
import Foundation

@MainActor
class AgentListViewModel: ObservableObject {
    @Published var agents: [AgentSession] = []

    var foregroundAgents: [AgentSession] {
        agents.filter { !$0.isBackground && $0.createdByAgentId == nil }
            .sorted { a, b in
                // Coordinator (spec-writer) first
                if a.specialist == "spec-writer" && b.specialist != "spec-writer" { return true }
                if a.specialist != "spec-writer" && b.specialist == "spec-writer" { return false }
                // Then by creation time (newest first)
                return (a.createdAt ?? "") > (b.createdAt ?? "")
            }
    }

    func delegatedAgents(for parentId: String) -> [AgentSession] {
        agents.filter { $0.createdByAgentId == parentId }
            .sorted { ($0.createdAt ?? "") > ($1.createdAt ?? "") }
    }

    var standaloneBackgroundAgents: [AgentSession] {
        let foregroundIds = Set(foregroundAgents.map { $0.id })
        let existingAgentIds = Set(agents.map { $0.id })
        let delegatedIds = Set(agents.filter {
            guard let parentId = $0.createdByAgentId else { return false }
            return existingAgentIds.contains(parentId)
        }.map { $0.id })
        return agents.filter {
            $0.isBackground &&
            !foregroundIds.contains($0.id) &&
            !delegatedIds.contains($0.id) &&
            ($0.createdByAgentId == nil || !existingAgentIds.contains($0.createdByAgentId!))
        }
        .sorted { ($0.updatedAt ?? $0.createdAt ?? "") > ($1.updatedAt ?? $1.createdAt ?? "") }
    }
}

