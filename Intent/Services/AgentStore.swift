import Combine
import Foundation
import Observation

struct SpecialistInfo: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String
    var resolvedModel: String?     // Daemon-resolved default model preview (PROTOCOL §5.11)
    var resolvedProvider: String?  // Provider context the preview was resolved for
    var hidden: Bool = false  // Excluded from picker surfaces (PROTOCOL §5.11)
    var role: String?        // Picker metadata: "orchestrator" | "internal" (PROTOCOL §5.11)
    var teamAgents: [String] = []  // Orchestrator's advisory team roster (render-only, PROTOCOL §5.11)
    var hasReportedTeamAgents = false
    var icon: String?        // Built-in avatar design name; unknown/absent falls back (PROTOCOL §5.11)
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
    /// The top-level `agent.list` read for the current workspace. Reset on
    /// workspace change; a failure before any success shows an error with
    /// Retry instead of "No agents" or an endless loading placeholder.
    var loadPhase = LoadPhase.idle
    var isLoading: Bool { loadPhase.isLoading }
    /// True once an `agent.list` for the current workspace has succeeded.
    var hasLoaded: Bool { loadPhase.hasLoaded }

    let connectionManager: ConnectionManagerRouting
    let summaries: AgentSummaryStore?
    var workspaceId: String?
    let list = AgentListState()
    /// Opt in for workspace lists; name-resolution consumers still need all active rows.
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
        if let workspaceId {
            await fetchAgents(workspaceId: workspaceId)
        }
    }

    /// Synchronously reset the list and load gate for a workspace switch.
    /// Views call this from onChange(of: workspaceId) before scheduling the
    /// async fetch, so the empty state cannot render with the previous
    /// workspace's load phase while the fetch task has not started yet.
    func prepareForWorkspaceChange(to workspaceId: String) {
        guard self.workspaceId != workspaceId else { return }
        // Advance the workspace id now, not when the fetch task starts:
        // an in-flight response for the old workspace must already fail
        // the stale-response guard in _fetchAgents.
        self.workspaceId = workspaceId
        fetchDebounceTask?.cancel()
        list.reset()
        agents = []
        loadPhase = .idle
    }

    func fetchAgents(workspaceId: String) async {
        let workspaceChanged = self.workspaceId != workspaceId
        // If workspace changed, clear agents immediately to prevent stale data
        prepareForWorkspaceChange(to: workspaceId)

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
            // The debounce task is unstructured, so cancelling the caller (e.g.
            // the view's deferred swipe-back refresh on disappear) must be
            // forwarded to it explicitly. Each debounce task belongs to exactly
            // one caller — a newer fetch already cancelled and replaced it — so
            // this never cancels a newer, unrelated fetch.
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
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
            // Refresh the agents list immediately (bypass debounce)
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
        // Remove from local array
        agents.removeAll { $0.id == agentId }
    }

    /// Sets the daemon-owned per-agent notification mute via
    /// `agent.update { changes: { notificationsMuted } }` (PROTOCOL §5.5).
    /// The result's `AgentLite` echoes the new value and is applied to the
    /// local row immediately; the daemon's `agent:updated` push then
    /// converges every other client through the ordinary refetch.
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

        // Only handle agent events for our workspace
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

    /// Bus channels this store consumes. Every catalog type on them must be in
    /// exactly one table below (`IntentTests/EventCatalogCoverageTests.swift`).
    nonisolated static let handledChannels = ["agent:"]

    /// Explicit allowlist (mirrors WorkspaceStore): only events that can
    /// change a field an `AgentSession` row renders refetch `agent.list`.
    /// Lifecycle events cover status and the streaming/processing/
    /// responding flags at turn boundaries; `agent:updated` carries
    /// name/model/effort, the pending-questions markers, digest and
    /// attention-cleared; `agent:retired`/`agent:restored` change list
    /// membership; `agent:last-message` fires once per persisted
    /// transcript row and feeds lastAgentResponse/lastUserMessage/
    /// lastMessageRole; `agent:attention-requested` feeds the pending
    /// attention request.
    nonisolated static let refetchEventTypes: Set<String> = [
        "agent:started", "agent:completed", "agent:failed", "agent:created",
        "agent:deleted", "agent:idle", "agent:status-changed", "agent:renamed",
        "agent:updated", "agent:retired", "agent:restored",
        "agent:last-message", "agent:attention-requested"
    ]

    /// Deliberately ignored: no rendered field depends on them, and several
    /// fire per token or per tool call mid-turn.
    nonisolated static let ignoredEventTypes: Set<String> = [
        // `agent:stream:*` — including `agent:stream:end`, since the turn's
        // persisted row arrives as `agent:last-message` and the flag flip as
        // `agent:idle`/`agent:status-changed`. This is an accepted trade-off:
        // a row's last-message preview refreshes at `agent:last-message` /
        // `agent:idle` rather than on every mid-turn activity tick, in
        // exchange for not refetching the list per token.
        "agent:stream:activity", "agent:stream:end", "agent:stream:start",
        "agent:stream:status", "agent:tool:call",
        // `agent:message` is a lean echo (`agent:last-message` is the
        // content-bearing companion); the `agent:message:*` /
        // `agent:user-message:sent` delivery markers carry no row field.
        "agent:message", "agent:message:delivery-failed", "agent:message:received",
        "agent:message:sent", "agent:user-message:sent",
        // `agent:permission:*`, `agent:process:*`, `agent:queue:*`,
        // `agent:subscriptions-*` and the subscription wake bookkeeping:
        // isWaitingForOtherAgents is picked up at the adjacent
        // idle/status-changed boundary.
        "agent:permission:request", "agent:permission:resolved",
        "agent:process:evicted", "agent:process:queued", "agent:process:resumed",
        "agent:queue:processing", "agent:queue:processing-cancelled",
        "agent:queue:stale-message", "agent:queue:updated",
        "agent:subscribed", "agent:unsubscribed", "agent:subscriptions-changed",
        "agent:subscriptions-restored", "agent:woken-by-subscription",
        // Event-delivery bookkeeping between agents; nothing rendered.
        "agent:delivery-confirmed", "agent:event-delivery-failed",
        "agent:event-delivery-timeout",
        // Deletion scheduling: list membership only changes at `agent:deleted`.
        "agent:delete-cancelled", "agent:delete-scheduled",
        // Session token/cost stats are not part of the list row.
        "agent:session-stats-changed"
    ]

    /// Pure classification of one event; `nil` means the tables above do not
    /// name the type, which `handleEvent` treats as ignore.
    nonisolated static func classify(
        type: String,
        // The shared classifier signature accepts absent event data even when only its type is needed.
        data _: [String: Any]? // swiftlint:disable:this discouraged_optional_collection
    ) -> EventClassification? {
        if refetchEventTypes.contains(type) { return .refetch }
        if ignoredEventTypes.contains(type) { return .ignore }
        return nil
    }
}
