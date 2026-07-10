import Foundation
import Combine

struct SpecialistInfo: Identifiable {
    let id: String
    let name: String
    let description: String
    let modelTier: String?  // "fast", "balanced", "smart"
}

@MainActor
class AgentStore: ObservableObject {
    @Published var agents: [AgentSession] = []
    @Published var isLoading = false

    private var workspaceId: String?
    private var eventHandlerId: UUID?
    private var fetchDebounceTask: Task<Void, Never>?

    func fetchAgents(workspaceId: String) async {
        let workspaceChanged = self.workspaceId != workspaceId
        // If workspace changed, clear agents immediately to prevent stale data
        if workspaceChanged {
            agents = []
        }
        self.workspaceId = workspaceId

        // Debounce: cancel any pending fetch and wait 300ms before actually fetching
        // Skip debounce on first load (when workspace changed or no agents yet) for instant display
        fetchDebounceTask?.cancel()

        if workspaceChanged || agents.isEmpty {
            // First load — fetch immediately, no debounce
            await _fetchAgents(workspaceId: workspaceId)
        } else {
            // Subsequent fetches (e.g., from events) — debounce
            let task = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                await _fetchAgents(workspaceId: workspaceId)
            }
            fetchDebounceTask = task
            await task.value
        }
    }

    private func _fetchAgents(workspaceId: String) async {
        // Only show loading indicator if we have no agents to display
        if agents.isEmpty {
            isLoading = true
        }
        do {
            let result = try await ConnectionManager.shared.request(
                "agent.list",
                params: ["workspaceId": workspaceId]
            )
            if let dict = result as? [String: Any],
               let items = dict["agents"] as? [[String: Any]] {
                agents = items.compactMap { AgentSession.parseAgent($0) }
            }
        } catch {
            print("[AgentStore] Failed to fetch agents: \(error)")
        }
        isLoading = false
    }

    func startObservingEvents() {
        // Remove old handler to prevent accumulation
        if let handlerId = eventHandlerId {
            ConnectionManager.shared.removeEventHandler(id: handlerId)
        }
        eventHandlerId = ConnectionManager.shared.onEvent { [weak self] method, params in
            Task { @MainActor [weak self] in
                self?.handleEvent(method, params: params)
            }
        }
    }

    func fetchSpecialists() async -> [SpecialistInfo] {
        do {
            let result = try await ConnectionManager.shared.request("specialist.list")
            if let dict = result as? [String: Any],
               let items = dict["specialists"] as? [[String: Any]] {
                return items.compactMap { item in
                    guard let id = item["id"] as? String,
                          let name = item["name"] as? String,
                          let description = item["description"] as? String else { return nil }
                    return SpecialistInfo(
                        id: id,
                        name: name,
                        description: description,
                        modelTier: item["modelTier"] as? String
                    )
                }
            }
        } catch {
            print("[AgentStore] Failed to fetch specialists: \(error)")
        }
        return []
    }

    func createAgent(workspaceId: String, specialistId: String?, name: String? = nil) async throws -> AgentSession? {
        var params: [String: Any] = ["workspaceId": workspaceId]
        if let specialistId = specialistId {
            params["specialistId"] = specialistId
        }
        if let name = name {
            params["name"] = name
        }

        let result = try await ConnectionManager.shared.request("agent.create", params: params)
        if let dict = result as? [String: Any],
           let agentDict = dict["agent"] as? [String: Any] {
            let agent = AgentSession.parseAgent(agentDict)
            // Refresh the agents list immediately (bypass debounce)
            await _fetchAgents(workspaceId: workspaceId)
            return agent
        }
        return nil
    }

    func deleteAgent(agentId: String, workspaceId: String) async throws {
        let _ = try await ConnectionManager.shared.request(
            "agent.delete",
            params: ["agentId": agentId, "workspaceId": workspaceId]
        )
        // Remove from local array
        agents.removeAll { $0.id == agentId }
    }

    private func handleEvent(_ method: String, params: Any) {
        guard let dict = params as? [String: Any] else { return }

        let event: [String: Any]
        if let innerEvent = dict["event"] as? [String: Any] {
            event = innerEvent
        } else {
            event = dict
        }

        guard let eventType = event["type"] as? String else { return }

        // Only handle agent events for our workspace
        let eventWorkspaceId = event["workspaceId"] as? String
        guard eventWorkspaceId == workspaceId || eventWorkspaceId == nil else { return }

        switch eventType {
        case let t where t.hasPrefix("agent:"):
            guard let workspaceId = workspaceId else { return }
            Task { await fetchAgents(workspaceId: workspaceId) }
        default:
            break
        }
    }
}

