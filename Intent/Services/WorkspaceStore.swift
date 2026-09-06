import Foundation
import Combine
import Observation

@MainActor
@Observable class WorkspaceStore {
    static let shared = WorkspaceStore()

    var workspaces: [Workspace] = []
    var lastUpdated: Date?
    var isLoading = false

    @ObservationIgnored private var connectionObserver: AnyCancellable?
    @ObservationIgnored private var eventHandlerId: UUID?
    @ObservationIgnored private let connectionManager: ConnectionManagerRouting

    /// Tracks the highest-known lastActivity per workspace so optimistic
    /// event-driven timestamps are never overwritten by stale server data.
    @ObservationIgnored var lastActivityHighWaterMark: [String: String] = [:]

    // Live-state subscription tracking
    @ObservationIgnored private var workspaceSubscriptionId: String?
    @ObservationIgnored private var workspaceReconciler: DeltaReconciler<Workspace>?
    @ObservationIgnored private var workspaceLive = false
    @ObservationIgnored private var resnapshotInProgress = false

    /// Internal (not private) so `BackendSessionRegistry` can construct one
    /// additional instance per pinned backend session over that session's
    /// connection; `.shared` remains the process-wide default over
    /// `ConnectionManager.shared`.
    init(connectionManager: ConnectionManagerRouting = ConnectionManager.shared) {
        self.connectionManager = connectionManager
        observeConnection()
    }

    /// Test-only initializer that skips connection observation
    init(forTesting: Bool) {
        self.connectionManager = ConnectionManager.shared
        // No connection observation for unit tests
    }

    /// Test-only helper to set reconciler for race condition testing
    func setTestReconciler(_ reconciler: DeltaReconciler<Workspace>) async {
        await MainActor.run {
            workspaceReconciler = reconciler
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
        // Reset live-state tracking on new connection
        workspaceLive = false
        // Unregister old handler if reconnecting (defensive: subscription is invalid after disconnect)
        if let oldId = workspaceSubscriptionId {
            connectionManager.unregisterSubscriptionHandler(id: oldId)
        }
        workspaceSubscriptionId = nil
        workspaceReconciler = nil
        resnapshotInProgress = false

        await fetchAll()
        await subscribeToEvents()
        await subscribeLiveState()
    }

    // MARK: - Fetch

    func fetchAll() async {
        await _fetchAll()
    }

    private func _fetchAll() async {
        isLoading = true
        do {
            let result = try await connectionManager.request("workspace.list")
            var parsed = Self.parseWorkspaces(from: result)
            applyHighWaterMarks(to: &parsed)
            publishFetchedWorkspaces(parsed)
        } catch {
            AppLog.workspace.error("[WorkspaceStore] Failed to fetch workspaces: \(error)")
        }
        isLoading = false
    }

    /// Publishes a fetched workspace list. `lastUpdated` is set **before** `workspaces`
    /// so observers that gate on "fetched at least once" (e.g. AppCoordinator's
    /// missing-workspace validation) see a non-nil `lastUpdated` on the very first
    /// post-fetch change.
    func publishFetchedWorkspaces(_ parsed: [Workspace]) {
        lastUpdated = Date()
        workspaces = parsed
    }

    // MARK: - Upsert

    /// Upserts a workspace (e.g. from a workspace.create response): replaces the
    /// existing row when the id is already present — the live subscription delta
    /// may have added it before the RPC response returned — otherwise inserts at
    /// the top. Also seeds the live reconciler so the row isn't dropped by the
    /// next delta apply.
    func addOrUpdate(_ workspace: Workspace) {
        var merged = [workspace]
        applyHighWaterMarks(to: &merged)
        let row = merged[0]
        if let index = workspaces.firstIndex(where: { $0.id == row.id }) {
            workspaces[index] = row
        } else {
            workspaces.insert(row, at: 0)
        }
        workspaceReconciler?.seed(id: row.id, value: row)
    }

    /// Merges high-water-mark timestamps into the given workspaces array so
    /// optimistic event-driven timestamps are never overwritten by stale server data.
    func applyHighWaterMarks(to workspaces: inout [Workspace]) {
        for i in workspaces.indices {
            let ws = workspaces[i]
            if let hwm = lastActivityHighWaterMark[ws.id],
               let serverTs = ws.lastActivity,
               hwm > serverTs {
                workspaces[i] = Workspace(
                    id: ws.id,
                    title: ws.title,
                    branch: ws.branch,
                    baseRef: ws.baseRef,
                    status: ws.status,
                    activity: ws.activity,
                    displayStatus: ws.displayStatus,
                    attention: ws.attention,
                    waiting: ws.waiting,
                    lastActivity: hwm,
                    updatedAt: ws.updatedAt,
                    repositoryOwner: ws.repositoryOwner,
                    repositoryName: ws.repositoryName,
                    prStatus: ws.prStatus,
                    prNumber: ws.prNumber,
                    diffSummaryTotalFiles: ws.diffSummaryTotalFiles,
                    taskStatsTotal: ws.taskStatsTotal,
                    taskStatsCompleted: ws.taskStatsCompleted,
                    taskStatsInProgress: ws.taskStatsInProgress,
                    agentSummaryCount: ws.agentSummaryCount,
                    agentSummaryAgents: ws.agentSummaryAgents,
                    pullRequests: ws.pullRequests,
                    activePullRequest: ws.activePullRequest
                )
            }
        }
    }

    // MARK: - Event subscription

    private func subscribeToEvents() async {
        // Remove old handler to prevent accumulation on reconnect
        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
        }

        // Register event handler on the session's connection
        // (server subscription is handled centrally by ConnectionManager.subscribeToAllEvents)
        eventHandlerId = connectionManager.onEvent { [weak self] method, params in
            Task { @MainActor in
                self?.handleEvent(method, params: params)
            }
        }
    }

    private func subscribeLiveState() async {
        // Initialize workspace reconciler
        workspaceReconciler = DeltaReconciler<Workspace>(
            getId: { dict in dict["id"] as? String },
            normalize: { dict in WorkspaceStore.parseWorkspace(dict) }
        )

        // Try to subscribe - if server doesn't support it, error response falls back to legacy
        do {
            let result = try await connectionManager.request("workspace.subscribe", params: [
                "replaceGroup": "ios-workspaces"
            ])
            if let dict = result as? [String: Any],
               let subId = dict["subscriptionId"] as? String {
                // Unregister old handler if we had one
                if let oldId = workspaceSubscriptionId {
                    connectionManager.unregisterSubscriptionHandler(id: oldId)
                }
                workspaceSubscriptionId = subId
                // Register handler immediately in same MainActor tick (preserves sync-capture guarantee)
                connectionManager.registerSubscriptionHandler(id: subId) { [weak self] push in
                    self?.handleSubscriptionPush(push)
                }
                AppLog.workspace.info("[WorkspaceStore] Subscribed to workspace.subscribe: \(subId)")
            }
        } catch {
            AppLog.workspace.warning("[WorkspaceStore] workspace.subscribe failed: \(error), falling back to legacy")
        }
    }

    func handleEvent(_ method: String, params: Any) {
        // Handle subscription.push for live-state updates (test injection compatibility)
        if let push = SubscriptionPush.parse(method: method, params: params) {
            handleSubscriptionPush(push)
            return
        }

        guard let dict = params as? [String: Any] else { return }

        // Events from websocket-event-bridge are wrapped:
        // { subscriptionId, event: { type, workspaceId, timestamp, data } }
        let event: [String: Any]
        if let innerEvent = dict["event"] as? [String: Any] {
            event = innerEvent
        } else {
            event = dict
        }

        guard let eventType = event["type"] as? String else { return }

        AppLog.workspace.debug("[WorkspaceStore] Received event: \(eventType)")

        let eventTimestamp = event["timestamp"] as? String ?? ISO8601DateFormatter().string(from: Date())
        let eventWorkspaceId = event["workspaceId"] as? String

        switch eventType {
        // All 8 agent lifecycle events (matching cloudlands-fe AGENT_LIFECYCLE_EVENTS)
        case "agent:started", "agent:completed", "agent:failed", "agent:created",
             "agent:deleted", "agent:idle", "agent:status-changed", "agent:renamed":
            // Update lastActivity locally for immediate UI feedback
            if let wsId = eventWorkspaceId {
                updateLocalLastActivity(workspaceId: wsId, timestamp: eventTimestamp)
            }
            // Only refetch if not in live mode (avoid double-apply)
            if !workspaceLive {
                Task { await fetchAll() }
            }

        case let t where t.hasPrefix("workspace:"):
            // Check for workspace:updated with lastActivity changes
            if eventType == "workspace:updated",
               let data = event["data"] as? [String: Any],
               let changes = data["changes"] as? [String: Any],
               let lastActivity = changes["lastActivity"] as? String,
               let wsId = eventWorkspaceId {
                updateLocalLastActivity(workspaceId: wsId, timestamp: lastActivity)
            }
            // workspace:waiting-changed is self-sufficient ({ workspaceId, waiting },
            // transition-only, protocol 6.17) — patch the row in place, no refetch.
            if eventType == "workspace:waiting-changed",
               let data = event["data"] as? [String: Any],
               let waiting = data["waiting"] as? Bool,
               let wsId = (data["workspaceId"] as? String) ?? eventWorkspaceId {
                updateWaiting(workspaceId: wsId, waiting: waiting)
            }
            // Only refetch if not in live mode (avoid double-apply)
            if !workspaceLive {
                if eventType == "workspace:activity-changed" ||
                   eventType == "workspace:displayStatus-changed" ||
                   eventType == "workspace:attention-changed" ||
                   eventType == "workspace:updated" ||
                   eventType == "workspace:deleted" {
                    Task { await fetchAll() }
                }
            }

        case let t where t.hasPrefix("agent:"):
            // Unknown agent event — log and ignore (all known types handled above)
            AppLog.workspace.debug("[WorkspaceStore] Ignoring unknown agent event: \(t)")

        default:
            break
        }
    }

    private func handleSubscriptionPush(_ push: SubscriptionPush) {
        // Only process pushes if we have a reconciler ready
        // (reconciler is initialized synchronously before subscribe request, so any
        // push arriving between subscribe-sent and response-received is safe to process)
        guard let reconciler = workspaceReconciler else {
            return
        }

        // ConnectionManager now routes pushes by subscriptionId at the transport layer,
        // so this handler only receives pushes for our exact subscriptionId.
        // No per-store gate needed (single source of truth is the router)

        switch push.kind {
        case .snapshot:
            guard let rawItems = push.snapshot else { return }
            workspaceLive = true
            reconciler.applySnapshot(seq: push.seq, rawItems: rawItems)
            var parsed = reconciler.values()
            applyHighWaterMarks(to: &parsed)
            publishFetchedWorkspaces(parsed)
            AppLog.workspace.debug("[WorkspaceStore] Applied snapshot with \(rawItems.count) workspaces, seq=\(push.seq)")

        case .delta:
            guard let delta = push.delta else { return }
            if reconciler.applyDelta(seq: push.seq, delta: delta) {
                var parsed = reconciler.values()
                applyHighWaterMarks(to: &parsed)
                publishFetchedWorkspaces(parsed)
                AppLog.workspace.debug("[WorkspaceStore] Applied delta seq=\(push.seq), added=\(delta.added.count), updated=\(delta.updated.count), removed=\(delta.removedIds.count)")
            } else {
                // Gap detected — resnapshot (guard against storm)
                if !resnapshotInProgress {
                    resnapshotInProgress = true
                    AppLog.workspace.warning("[WorkspaceStore] Sequence gap detected at seq=\(push.seq), resubscribing...")
                    Task { await resnapshot() }
                }
            }
        }
    }

    private func resnapshot() async {
        resnapshotInProgress = true
        defer { resnapshotInProgress = false }

        workspaceLive = false
        workspaceReconciler?.reset()

        if let subId = workspaceSubscriptionId {
            // Unregister handler before unsubscribing
            connectionManager.unregisterSubscriptionHandler(id: subId)
            do {
                let _ = try await connectionManager.request("workspace.unsubscribe", params: [
                    "subscriptionId": subId
                ])
            } catch {
                AppLog.workspace.error("[WorkspaceStore] workspace.unsubscribe failed: \(error)")
            }
        }

        workspaceSubscriptionId = nil

        // Re-subscribe and refetch to bridge
        await subscribeLiveState()
        await fetchAll()
    }

    func updateLocalLastActivity(workspaceId: String, timestamp: String) {
        // Update high-water mark — only store if newer than existing entry
        if let existing = lastActivityHighWaterMark[workspaceId] {
            if timestamp > existing {
                lastActivityHighWaterMark[workspaceId] = timestamp
            }
        } else {
            lastActivityHighWaterMark[workspaceId] = timestamp
        }

        let effectiveTimestamp = lastActivityHighWaterMark[workspaceId] ?? timestamp

        if let index = workspaces.firstIndex(where: { $0.id == workspaceId }) {
            let ws = workspaces[index]
            workspaces[index] = Workspace(
                id: ws.id,
                title: ws.title,
                branch: ws.branch,
                baseRef: ws.baseRef,
                status: ws.status,
                activity: ws.activity,
                displayStatus: ws.displayStatus,
                attention: ws.attention,
                waiting: ws.waiting,
                lastActivity: effectiveTimestamp,
                updatedAt: ws.updatedAt,
                repositoryOwner: ws.repositoryOwner,
                repositoryName: ws.repositoryName,
                prStatus: ws.prStatus,
                prNumber: ws.prNumber,
                diffSummaryTotalFiles: ws.diffSummaryTotalFiles,
                taskStatsTotal: ws.taskStatsTotal,
                taskStatsCompleted: ws.taskStatsCompleted,
                taskStatsInProgress: ws.taskStatsInProgress,
                agentSummaryCount: ws.agentSummaryCount,
                agentSummaryAgents: ws.agentSummaryAgents,
                pullRequests: ws.pullRequests,
                activePullRequest: ws.activePullRequest
            )
        }
    }

    /// Applies a workspace:waiting-changed transition in place (protocol 6.17).
    /// The event is self-sufficient, so no refetch is needed; the reconciler is
    /// reseeded so the next live delta doesn't revert the flag.
    func updateWaiting(workspaceId: String, waiting: Bool) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }),
              workspaces[index].waiting != waiting else { return }
        let ws = workspaces[index]
        let updated = Workspace(
            id: ws.id,
            title: ws.title,
            branch: ws.branch,
            baseRef: ws.baseRef,
            status: ws.status,
            activity: ws.activity,
            displayStatus: ws.displayStatus,
            attention: ws.attention,
            waiting: waiting,
            lastActivity: ws.lastActivity,
            updatedAt: ws.updatedAt,
            repositoryOwner: ws.repositoryOwner,
            repositoryName: ws.repositoryName,
            prStatus: ws.prStatus,
            prNumber: ws.prNumber,
            diffSummaryTotalFiles: ws.diffSummaryTotalFiles,
            taskStatsTotal: ws.taskStatsTotal,
            taskStatsCompleted: ws.taskStatsCompleted,
            taskStatsInProgress: ws.taskStatsInProgress,
            agentSummaryCount: ws.agentSummaryCount,
            agentSummaryAgents: ws.agentSummaryAgents,
            pullRequests: ws.pullRequests,
            activePullRequest: ws.activePullRequest
        )
        workspaces[index] = updated
        workspaceReconciler?.seed(id: updated.id, value: updated)
    }

    /// Optimistically clears the unread attention flag locally (guarded on
    /// "unread", mirroring the server-side workspace.markSeen guard) so the
    /// dot disappears immediately; the authoritative state converges via
    /// workspace:attention-changed / the live subscription delta.
    func clearUnreadAttentionLocally(workspaceId: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }),
              workspaces[index].attention == "unread" else { return }
        let ws = workspaces[index]
        let updated = Workspace(
            id: ws.id,
            title: ws.title,
            branch: ws.branch,
            baseRef: ws.baseRef,
            status: ws.status,
            activity: ws.activity,
            displayStatus: ws.displayStatus,
            attention: "none",
            waiting: ws.waiting,
            lastActivity: ws.lastActivity,
            updatedAt: ws.updatedAt,
            repositoryOwner: ws.repositoryOwner,
            repositoryName: ws.repositoryName,
            prStatus: ws.prStatus,
            prNumber: ws.prNumber,
            diffSummaryTotalFiles: ws.diffSummaryTotalFiles,
            taskStatsTotal: ws.taskStatsTotal,
            taskStatsCompleted: ws.taskStatsCompleted,
            taskStatsInProgress: ws.taskStatsInProgress,
            agentSummaryCount: ws.agentSummaryCount,
            agentSummaryAgents: ws.agentSummaryAgents,
            pullRequests: ws.pullRequests,
            activePullRequest: ws.activePullRequest
        )
        workspaces[index] = updated
        workspaceReconciler?.seed(id: updated.id, value: updated)
    }

    // MARK: - Parsing

    static func parseWorkspaces(from result: Any) -> [Workspace] {
        guard let dict = result as? [String: Any],
              let items = dict["workspaces"] as? [[String: Any]] else {
            guard let items = result as? [[String: Any]] else { return [] }
            return items.compactMap { parseWorkspace($0) }
        }
        return items.compactMap { parseWorkspace($0) }
    }

    static func parseWorkspace(_ dict: [String: Any]) -> Workspace? {
        guard let id = dict["id"] as? String,
              let title = dict["title"] as? String else { return nil }

        let diffSummary = dict["diffSummary"] as? [String: Any]
        let taskStats = dict["taskStats"] as? [String: Any]
        let agentSummary = dict["agentSummary"] as? [String: Any]

        // DEBUG: Log agent summary data
        AppLog.workspace.debug("[WorkspaceStore] Parsing workspace '\(title)': agentSummary=\(agentSummary != nil ? "present" : "nil"), count=\(agentSummary?["count"] ?? "nil"), agents=\((agentSummary?["agents"] as? [[String: Any]])?.count ?? 0)")
        if let agents = agentSummary?["agents"] as? [[String: Any]] {
            for agent in agents {
                AppLog.workspace.debug("[WorkspaceStore]   Agent: id=\(agent["id"] ?? "?"), name=\(agent["name"] ?? "?"), status=\(agent["status"] ?? "?")")
            }
        }
        // END DEBUG

        var pullRequests: [WorkspacePullRequest]?
        if let rawPrs = dict["pullRequests"] as? [[String: Any]] {
            pullRequests = rawPrs.compactMap { WorkspacePullRequest(wire: $0) }
        }

        var activePullRequest: WorkspacePullRequest?
        if let rawActivePr = dict["activePullRequest"] as? [String: Any] {
            activePullRequest = WorkspacePullRequest(wire: rawActivePr)
        }

        var agentInfos: [WorkspaceAgentInfo]?
        if let agents = agentSummary?["agents"] as? [[String: Any]] {
            agentInfos = agents.compactMap { agentDict -> WorkspaceAgentInfo? in
                guard let agentId = agentDict["id"] as? String,
                      let name = agentDict["name"] as? String,
                      let status = agentDict["status"] as? String else { return nil }
                return WorkspaceAgentInfo(
                    id: agentId,
                    name: name,
                    status: status,
                    specialist: agentDict["specialist"] as? String,
                    lastActivity: agentDict["lastActivity"] as? String,
                    isStreaming: agentDict["isStreaming"] as? Bool ?? false,
                    isResponding: agentDict["isResponding"] as? Bool ?? false
                )
            }
        }

        return Workspace(
            id: id,
            title: title,
            branch: dict["branch"] as? String,
            baseRef: dict["baseRef"] as? String,
            status: dict["status"] as? String,
            activity: dict["activity"] as? String,
            displayStatus: dict["displayStatus"] as? String,
            attention: dict["attention"] as? String,
            waiting: dict["waiting"] as? Bool ?? false,
            lastActivity: dict["lastActivity"] as? String,
            updatedAt: dict["updatedAt"] as? String,
            repositoryOwner: dict["repositoryOwner"] as? String,
            repositoryName: dict["repositoryName"] as? String ?? dict["repo"] as? String,
            prStatus: dict["prStatus"] as? String,
            prNumber: dict["prNumber"] as? Int,
            diffSummaryTotalFiles: diffSummary?["totalFiles"] as? Int,
            taskStatsTotal: taskStats?["total"] as? Int,
            taskStatsCompleted: taskStats?["completed"] as? Int,
            taskStatsInProgress: taskStats?["inProgress"] as? Int,
            agentSummaryCount: agentSummary?["count"] as? Int,
            agentSummaryAgents: agentInfos,
            pullRequests: pullRequests,
            activePullRequest: activePullRequest
        )
    }
}

