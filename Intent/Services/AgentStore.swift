import Combine
import Foundation
import Observation

struct SpecialistInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    var resolvedModel: String?
    var resolvedProvider: String?
    var hidden: Bool = false
    var role: String?
    var teamAgents: [String] = []
    var hasReportedTeamAgents = false
    var icon: String?
}

extension Array where Element == SpecialistInfo {
    var pickable: [SpecialistInfo] {
        filter { !$0.hidden }
    }

    var modalPickable: [SpecialistInfo] {
        pickable.filter { $0.role != "internal" }
    }

    var orchestrator: SpecialistInfo? {
        filter { $0.role == "orchestrator" }.min { $0.id < $1.id }
    }
}

extension SpecialistInfo {
    static func daemonDefaultLabel(for specialist: SpecialistInfo?, providerId: String?) -> String {
        if let resolved = specialist?.resolvedModel,
           specialist?.resolvedProvider == providerId {
            return "Default (\(resolved))"
        }
        return "Provider default"
    }
}

extension SpecialistInfo {
    init?(wire item: [String: Any]) {
        guard let id = item["id"] as? String,
              let name = item["name"] as? String,
              let description = item["description"] as? String else { return nil }
        self.init(
            id: id,
            name: AgentSession.displayName(for: name),
            description: id == "chief-of-staff"
                ? description.replacingOccurrences(of: "Chief of Staff", with: "Assistant", options: .caseInsensitive)
                : description,
            resolvedModel: item["resolvedModel"] as? String,
            resolvedProvider: item["resolvedProvider"] as? String,
            hidden: item["hidden"] as? Bool ?? false,
            role: item["role"] as? String,
            teamAgents: item["teamAgents"] as? [String] ?? [],
            hasReportedTeamAgents: item["teamAgents"] is [String],
            icon: item["icon"] as? String
        )
    }
}

@MainActor
@Observable class AgentStore {
    var agents: [AgentSession] = []
    var loadPhase = LoadPhase.idle
    var isLoading: Bool { loadPhase.isLoading }
    var hasLoaded: Bool { loadPhase.hasLoaded }

    let connectionManager: ConnectionManagerRouting
    let summaries: AgentSummaryStore?
    var workspaceId: String?
    let list = AgentListState()
    let scopedLoading: Bool
    @ObservationIgnored private var eventHandlerId: UUID?
    private var fetchDebounceTask: Task<Void, Never>?
    private var connectionObserver: AnyCancellable?

    init(
        connectionManager: ConnectionManagerRouting = ConnectionManager.shared,
        summaries: AgentSummaryStore? = nil,
        scopedLoading: Bool = false
    ) {
        self.connectionManager = connectionManager
        self.summaries = summaries
        self.scopedLoading = scopedLoading
        observeConnection()
    }

    isolated deinit {
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
        if let workspaceId {
            await fetchAgents(workspaceId: workspaceId)
        }
    }

    func prepareForWorkspaceChange(to workspaceId: String) {
        guard self.workspaceId != workspaceId else { return }
        self.workspaceId = workspaceId
        fetchDebounceTask?.cancel()
        list.reset()
        agents = []
        loadPhase = .idle
    }

    func fetchAgents(workspaceId: String) async {
        let workspaceChanged = self.workspaceId != workspaceId
        prepareForWorkspaceChange(to: workspaceId)

        fetchDebounceTask?.cancel()

        if workspaceChanged || agents.isEmpty {
            await _fetchAgents(workspaceId: workspaceId)
        } else {
            let task = Task {
                try? await Task.sleep(for: Constants.AgentStore.fetchDebounce)
                guard !Task.isCancelled else { return }
                await _fetchAgents(workspaceId: workspaceId)
            }
            fetchDebounceTask = task
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
    }

    func startObservingEvents() {
        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
        }
        eventHandlerId = connectionManager.onEvent { [weak self] method, params in
            Task { @MainActor [weak self] in
                self?.handleEvent(method, params: params)
            }
        }
    }

    func suspendObservation() {
        fetchDebounceTask?.cancel()
        fetchDebounceTask = nil
        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
            eventHandlerId = nil
        }
        connectionObserver = nil
    }

    func resumeObservation() {
        if connectionObserver == nil {
            connectionObserver = connectionManager.connectionStatePublisher
                .dropFirst()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] state in
                    if state == .connected {
                        Task { await self?.onConnected() }
                    }
                }
        }
        startObservingEvents()
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

    func fetchProviders() async -> [ProviderInfo] {
        do {
            let result = try await connectionManager.request("host.providerAuthStatus")
            if let dict = result as? [String: Any],
               let items = dict["providers"] as? [[String: Any]] {
                return items.compactMap { item -> ProviderInfo? in
                    guard let id = item["id"] as? String else { return nil }
                    let authentication: ProviderAuthentication
                    switch item["authenticated"] as? Bool {
                    case true: authentication = .signedIn
                    case false: authentication = .signedOut
                    case nil: authentication = .unknown
                    }
                    return ProviderInfo(id: id, authenticated: authentication)
                }
            }
        } catch {
            AppLog.agents.error("[AgentStore] Failed to fetch providers: \(error)")
        }
        return []
    }

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
        if let specialistId {
            params["specialistId"] = specialistId
        }
        if let name {
            params["name"] = name
        }
        if let provider {
            params["provider"] = provider
        }
        if let model {
            params["model"] = model
        }

        let result = try await connectionManager.request("agent.create", params: params)
        if let dict = result as? [String: Any],
           let agentDict = dict["agent"] as? [String: Any] {
            let agent = AgentSession.parseAgent(agentDict)
            await _fetchAgents(workspaceId: workspaceId)
            return agent
        }
        return nil
    }

    func deleteAgent(agentId: String, workspaceId: String) async throws {
        _ = try await connectionManager.request(
            "agent.delete",
            params: ["agentId": agentId, "workspaceId": workspaceId]
        )
        agents.removeAll { $0.id == agentId }
    }

    func setNotificationsMuted(agentId: String, workspaceId: String, muted: Bool) async throws {
        let result = try await connectionManager.request(
            "agent.update",
            params: [
                "agentId": agentId,
                "workspaceId": workspaceId,
                "changes": ["notificationsMuted": muted]
            ]
        )
        guard let dict = result as? [String: Any],
              let agentDict = dict["agent"] as? [String: Any],
              let updated = AgentSession.parseAgent(agentDict),
              let index = agents.firstIndex(where: { $0.id == agentId }) else { return }
        agents[index] = updated
    }

    private func handleEvent(_: String, params: Any) {
        guard let dict = params as? [String: Any] else { return }

        let event: [String: Any]
        if let innerEvent = dict["event"] as? [String: Any] {
            event = innerEvent
        } else {
            event = dict
        }

        guard let eventType = event["type"] as? String else { return }

        let eventWorkspaceId = event["workspaceId"] as? String
        guard eventWorkspaceId == workspaceId || eventWorkspaceId == nil else { return }

        switch Self.classify(type: eventType, data: event["data"] as? [String: Any]) {
        case .refetch:
            guard let workspaceId else { return }
            Task {
                guard self.workspaceId == workspaceId else { return }
                await fetchAgents(workspaceId: workspaceId)
            }
        case .patchInPlace, .ignore, nil:
            break
        }
    }

    // MARK: - Event classification

    nonisolated static let handledChannels = ["agent:"]

    nonisolated static let refetchEventTypes: Set<String> = [
        "agent:started", "agent:completed", "agent:failed", "agent:created",
        "agent:deleted", "agent:idle", "agent:status-changed", "agent:renamed",
        "agent:updated", "agent:retired", "agent:restored",
        "agent:last-message", "agent:attention-requested"
    ]

    nonisolated static let ignoredEventTypes: Set<String> = [
        "agent:stream:activity", "agent:stream:end", "agent:stream:start",
        "agent:stream:status", "agent:tool:call",
        "agent:message", "agent:message:delivery-failed", "agent:message:received",
        "agent:message:sent", "agent:user-message:sent",
        "agent:permission:request", "agent:permission:resolved",
        "agent:process:evicted", "agent:process:queued", "agent:process:resumed",
        "agent:queue:processing", "agent:queue:processing-cancelled",
        "agent:queue:stale-message", "agent:queue:updated",
        "agent:subscribed", "agent:unsubscribed", "agent:subscriptions-changed",
        "agent:subscriptions-restored", "agent:woken-by-subscription",
        "agent:delivery-confirmed", "agent:event-delivery-failed",
        "agent:event-delivery-timeout",
        "agent:delete-cancelled", "agent:delete-scheduled",
        "agent:session-stats-changed"
    ]

    nonisolated static func classify(
        type: String,
        data _: [String: Any]? // swiftlint:disable:this discouraged_optional_collection
    ) -> EventClassification? {
        if refetchEventTypes.contains(type) { return .refetch }
        if ignoredEventTypes.contains(type) { return .ignore }
        return nil
    }
}
