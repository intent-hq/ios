import Combine
import Foundation
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
    init(forTesting _: Bool) {
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
            publishFetchedWorkspaces(Self.parseWorkspaces(from: result))
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
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = workspace
        } else {
            workspaces.insert(workspace, at: 0)
        }
        workspaceReconciler?.seed(id: workspace.id, value: workspace)
    }
}

extension WorkspaceStore {
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
            normalize: { dict in Self.parseWorkspace(dict) }
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

        let eventWorkspaceId = event["workspaceId"] as? String

        switch eventType {
        // All 8 agent lifecycle events (matching cloudlands-fe AGENT_LIFECYCLE_EVENTS).
        // lastActivity is never bumped locally: intentd derives it and pushes
        // workspace:updated { changes.lastActivity } at turn boundaries.
        case "agent:started", "agent:completed", "agent:failed", "agent:created",
             "agent:deleted", "agent:idle", "agent:status-changed", "agent:renamed":
            // Only refetch if not in live mode (avoid double-apply)
            if !workspaceLive {
                Task { await fetchAll() }
            }

        case let eventName where eventName.hasPrefix("workspace:"):
            // workspace:updated carrying lastActivity is an intentd-derived value —
            // patch the row in place as received.
            if eventType == "workspace:updated",
               let data = event["data"] as? [String: Any],
               let changes = data["changes"] as? [String: Any],
               let lastActivity = changes["lastActivity"] as? String,
               let wsId = eventWorkspaceId {
                updateLastActivity(workspaceId: wsId, lastActivity: lastActivity)
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

        case let eventName where eventName.hasPrefix("agent:"):
            // Unknown agent event — log and ignore (all known types handled above)
            AppLog.workspace.debug("[WorkspaceStore] Ignoring unknown agent event: \(eventName)")

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

        switch push.payload {
        case let .collectionSnapshot(rawItems), let .conversationSnapshot(rawItems, _):
            workspaceLive = true
            reconciler.applySnapshot(seq: push.seq, rawItems: rawItems)
            publishFetchedWorkspaces(reconciler.values())
            AppLog.workspace.debug("[WorkspaceStore] Applied snapshot with \(rawItems.count) workspaces, seq=\(push.seq)")

        case let .delta(delta):
            if reconciler.applyDelta(seq: push.seq, delta: delta) {
                publishFetchedWorkspaces(reconciler.values())
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
                _ = try await connectionManager.request("workspace.unsubscribe", params: [
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

    /// Applies an intentd-sent `lastActivity` (from `workspace:updated`
    /// `changes.lastActivity`) in place, exactly as received. The reconciler is
    /// reseeded so the next live delta doesn't revert the value.
    func updateLastActivity(workspaceId: String, lastActivity: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }),
              workspaces[index].lastActivity != lastActivity else { return }
        let workspace = workspaces[index]
        let updated = Workspace(
            id: workspace.id,
            title: workspace.title,
            branch: workspace.branch,
            baseRef: workspace.baseRef,
            status: workspace.status,
            activity: workspace.activity,
            displayStatus: workspace.displayStatus,
            attention: workspace.attention,
            waiting: workspace.waiting,
            lastActivity: lastActivity,
            createdAt: workspace.createdAt,
            updatedAt: workspace.updatedAt,
            repositoryOwner: workspace.repositoryOwner,
            repositoryName: workspace.repositoryName,
            prStatus: workspace.prStatus,
            prNumber: workspace.prNumber,
            diffSummaryTotalFiles: workspace.diffSummaryTotalFiles,
            taskStatsTotal: workspace.taskStatsTotal,
            taskStatsCompleted: workspace.taskStatsCompleted,
            taskStatsInProgress: workspace.taskStatsInProgress,
            agentSummaryCount: workspace.agentSummaryCount,
            agentSummaryAgents: workspace.agentSummaryAgents,
            pullRequests: workspace.pullRequests,
            agentSummaryWasReported: workspace.agentSummaryWasReported,
            pullRequestsWereReported: workspace.pullRequestsWereReported,
            activePullRequest: workspace.activePullRequest
        )
        workspaces[index] = updated
        workspaceReconciler?.seed(id: updated.id, value: updated)
    }

    /// Applies a workspace:waiting-changed transition in place (protocol 6.17).
    /// The event is self-sufficient, so no refetch is needed; the reconciler is
    /// reseeded so the next live delta doesn't revert the flag.
    func updateWaiting(workspaceId: String, waiting: Bool) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }),
              workspaces[index].waiting != waiting else { return }
        let workspace = workspaces[index]
        let updated = Workspace(
            id: workspace.id,
            title: workspace.title,
            branch: workspace.branch,
            baseRef: workspace.baseRef,
            status: workspace.status,
            activity: workspace.activity,
            displayStatus: workspace.displayStatus,
            attention: workspace.attention,
            waiting: waiting,
            lastActivity: workspace.lastActivity,
            createdAt: workspace.createdAt,
            updatedAt: workspace.updatedAt,
            repositoryOwner: workspace.repositoryOwner,
            repositoryName: workspace.repositoryName,
            prStatus: workspace.prStatus,
            prNumber: workspace.prNumber,
            diffSummaryTotalFiles: workspace.diffSummaryTotalFiles,
            taskStatsTotal: workspace.taskStatsTotal,
            taskStatsCompleted: workspace.taskStatsCompleted,
            taskStatsInProgress: workspace.taskStatsInProgress,
            agentSummaryCount: workspace.agentSummaryCount,
            agentSummaryAgents: workspace.agentSummaryAgents,
            pullRequests: workspace.pullRequests,
            agentSummaryWasReported: workspace.agentSummaryWasReported,
            pullRequestsWereReported: workspace.pullRequestsWereReported,
            activePullRequest: workspace.activePullRequest
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
        let workspace = workspaces[index]
        let updated = Workspace(
            id: workspace.id,
            title: workspace.title,
            branch: workspace.branch,
            baseRef: workspace.baseRef,
            status: workspace.status,
            activity: workspace.activity,
            displayStatus: workspace.displayStatus,
            attention: "none",
            waiting: workspace.waiting,
            lastActivity: workspace.lastActivity,
            createdAt: workspace.createdAt,
            updatedAt: workspace.updatedAt,
            repositoryOwner: workspace.repositoryOwner,
            repositoryName: workspace.repositoryName,
            prStatus: workspace.prStatus,
            prNumber: workspace.prNumber,
            diffSummaryTotalFiles: workspace.diffSummaryTotalFiles,
            taskStatsTotal: workspace.taskStatsTotal,
            taskStatsCompleted: workspace.taskStatsCompleted,
            taskStatsInProgress: workspace.taskStatsInProgress,
            agentSummaryCount: workspace.agentSummaryCount,
            agentSummaryAgents: workspace.agentSummaryAgents,
            pullRequests: workspace.pullRequests,
            agentSummaryWasReported: workspace.agentSummaryWasReported,
            pullRequestsWereReported: workspace.pullRequestsWereReported,
            activePullRequest: workspace.activePullRequest
        )
        workspaces[index] = updated
        workspaceReconciler?.seed(id: updated.id, value: updated)
    }
}
