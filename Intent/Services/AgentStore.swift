import Foundation
import Combine
import Observation

struct SpecialistInfo: Identifiable {
    let id: String
    let name: String
    let description: String
    var resolvedModel: String?     // Daemon-resolved default model preview (PROTOCOL §5.11)
    var resolvedProvider: String?  // Provider context the preview was resolved for
    var hidden: Bool = false  // Excluded from picker surfaces (PROTOCOL §5.11)
    var role: String? = nil        // Picker metadata: "orchestrator" | "internal" (PROTOCOL §5.11)
    var teamAgents: [String]? = nil  // Orchestrator's advisory team roster (render-only, PROTOCOL §5.11)
    var icon: String? = nil        // Built-in avatar design name; unknown/absent falls back (PROTOCOL §5.11)
}

extension Array where Element == SpecialistInfo {
    /// Specialists eligible for picker surfaces — drops `hidden` ones
    /// (mirrors the FE's `filterPickableSpecialists`). By-id lookups
    /// should keep using the unfiltered list.
    var pickable: [SpecialistInfo] {
        filter { !$0.hidden }
    }

    /// Specialists eligible for the New Agent picker — the pickable set minus
    /// `role: "internal"` specialists (mirrors the FE's
    /// `filterModalPickableSpecialists`). Internal specialists stay in the
    /// unfiltered list for by-id lookups and non-picker surfaces.
    var modalPickable: [SpecialistInfo] {
        pickable.filter { $0.role != "internal" }
    }

    /// The resolved orchestrator: the first `role: "orchestrator"` specialist
    /// by id order (mirrors the FE's `selectOrchestratorSpecialist`), or nil
    /// when no orchestrator exists.
    var orchestrator: SpecialistInfo? {
        filter { $0.role == "orchestrator" }.min { $0.id < $1.id }
    }
}

extension SpecialistInfo {
    /// Label for the daemon-default row of model pickers, shared by the agent
    /// and workspace creation flows: names the daemon-resolved default when
    /// the preview was computed for the given provider, else "Provider
    /// default" (the resolved fields are omitted when resolution yields the
    /// provider CLI default — PROTOCOL §5.11).
    static func daemonDefaultLabel(for specialist: SpecialistInfo?, providerId: String?) -> String {
        if let resolved = specialist?.resolvedModel,
           specialist?.resolvedProvider == providerId {
            return "Default (\(resolved))"
        }
        return "Provider default"
    }
}

extension SpecialistInfo {
    /// Decodes one `specialist.list` entry. Missing `hidden` means not hidden.
    init?(wire item: [String: Any]) {
        guard let id = item["id"] as? String,
              let name = item["name"] as? String,
              let description = item["description"] as? String else { return nil }
        self.init(
            id: id,
            name: name,
            description: description,
            resolvedModel: item["resolvedModel"] as? String,
            resolvedProvider: item["resolvedProvider"] as? String,
            hidden: item["hidden"] as? Bool ?? false,
            role: item["role"] as? String,
            teamAgents: item["teamAgents"] as? [String],
            icon: item["icon"] as? String
        )
    }
}

@MainActor
@Observable class AgentStore {
    var agents: [AgentSession] = []
    var isLoading = false
    /// True once an `agent.list` for the current workspace has completed
    /// successfully. Reset on workspace change; a failed fetch leaves it
    /// false so views keep the loading placeholder instead of "No agents".
    var hasLoaded = false

    let connectionManager: ConnectionManagerRouting
    private var workspaceId: String?
    @ObservationIgnored private var eventHandlerId: UUID?
    private var fetchDebounceTask: Task<Void, Never>?
    private var connectionObserver: AnyCancellable?

    init(connectionManager: ConnectionManagerRouting = ConnectionManager.shared) {
        self.connectionManager = connectionManager
        observeConnection()
    }

    isolated deinit {
        // Remove the handler directly while deinit is isolated to MainActor.
        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
        }
    }

    // MARK: - Connection observation

    private func observeConnection() {
        connectionObserver = connectionManager.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state == .connected {
                    Task { await self?.onConnected() }
                }
            }
    }

    private func onConnected() async {
        // Refetch on (re)connect: a fetch that failed pre-connection
        // (e.g. "Not connected") must be retried as soon as the
        // connection is up, not wait for a coincidental agent event.
        if let workspaceId = workspaceId {
            await fetchAgents(workspaceId: workspaceId)
        }
    }

    /// Synchronously reset the list and load gate for a workspace switch.
    /// Views call this from onChange(of: workspaceId) before scheduling the
    /// async fetch, so the empty state cannot render with the previous
    /// workspace's hasLoaded while the fetch task has not started yet.
    func prepareForWorkspaceChange(to workspaceId: String) {
        guard self.workspaceId != workspaceId else { return }
        // Advance the workspace id now, not when the fetch task starts:
        // an in-flight response for the old workspace must already fail
        // the stale-response guard in _fetchAgents.
        self.workspaceId = workspaceId
        agents = []
        hasLoaded = false
    }

    func fetchAgents(workspaceId: String) async {
        let workspaceChanged = self.workspaceId != workspaceId
        // If workspace changed, clear agents immediately to prevent stale data
        if workspaceChanged {
            agents = []
            hasLoaded = false
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
                try? await Task.sleep(for: Constants.AgentStore.fetchDebounce)
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
            let result = try await connectionManager.request(
                "agent.list",
                params: ["workspaceId": workspaceId]
            )
            // Guard: a stale response for a previous workspace must not
            // replace the current workspace's agents or flip hasLoaded. The
            // current workspace's own fetch manages isLoading.
            guard self.workspaceId == workspaceId else { return }
            if let dict = result as? [String: Any],
               let items = dict["agents"] as? [[String: Any]] {
                agents = items.compactMap { AgentSession.parseAgent($0) }
            }
            hasLoaded = true
        } catch {
            AppLog.agents.error("[AgentStore] Failed to fetch agents: \(error)")
        }
        isLoading = false
    }

    func startObservingEvents() {
        // Remove old handler to prevent accumulation
        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
        }
        eventHandlerId = connectionManager.onEvent { [weak self] method, params in
            Task { @MainActor [weak self] in
                self?.handleEvent(method, params: params)
            }
        }
    }

    func fetchSpecialists() async -> [SpecialistInfo] {
        do {
            let result = try await connectionManager.request("specialist.list")
            if let dict = result as? [String: Any],
               let items = dict["specialists"] as? [[String: Any]] {
                return items.compactMap { SpecialistInfo(wire: $0) }
            }
        } catch {
            AppLog.agents.error("[AgentStore] Failed to fetch specialists: \(error)")
        }
        return []
    }

    /// Fetches provider auth verdicts via `host.providerAuthStatus` (PROTOCOL §5.14).
    /// `authenticated` is tri-state: true / false / nil (unknown).
    func fetchProviders() async -> [ProviderInfo] {
        do {
            let result = try await connectionManager.request("host.providerAuthStatus")
            if let dict = result as? [String: Any],
               let items = dict["providers"] as? [[String: Any]] {
                return items.compactMap { item in
                    guard let id = item["id"] as? String else { return nil }
                    return ProviderInfo(id: id, authenticated: item["authenticated"] as? Bool)
                }
            }
        } catch {
            AppLog.agents.error("[AgentStore] Failed to fetch providers: \(error)")
        }
        return []
    }

    /// Fetches the per-provider model catalog via `models.list { providerId }` (PROTOCOL §5.30).
    func fetchModels(providerId: String) async -> [ModelInfo] {
        do {
            let result = try await connectionManager.request(
                "models.list",
                params: ["providerId": providerId]
            )
            if let dict = result as? [String: Any],
               let items = dict["models"] as? [[String: Any]] {
                return items.compactMap { item in
                    guard let id = item["id"] as? String,
                          let name = item["name"] as? String else { return nil }
                    return ModelInfo(
                        id: id,
                        name: name,
                        provider: item["provider"] as? String ?? providerId,
                        isDefault: item["isDefault"] as? Bool ?? false
                    )
                }
            }
        } catch {
            AppLog.agents.error("[AgentStore] Failed to fetch models for provider \(providerId): \(error)")
        }
        return []
    }

    func createAgent(
        workspaceId: String,
        specialistId: String?,
        name: String? = nil,
        provider: String? = nil,
        model: String? = nil
    ) async throws -> AgentSession? {
        var params: [String: Any] = ["workspaceId": workspaceId]
        if let specialistId = specialistId {
            params["specialistId"] = specialistId
        }
        if let name = name {
            params["name"] = name
        }
        if let provider = provider {
            params["provider"] = provider
        }
        if let model = model {
            params["model"] = model
        }

        let result = try await connectionManager.request("agent.create", params: params)
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
        let _ = try await connectionManager.request(
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

