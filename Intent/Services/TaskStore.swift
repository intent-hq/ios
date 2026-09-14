import Foundation
import Combine
import Observation

/// Observable task state for a single workspace.
@MainActor
@Observable class TaskStore {
    var tasks: [WorkspaceTask] = []
    var isLoading = false
    var lastUpdated: Date?

    @ObservationIgnored private var workspaceId: String
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var eventHandlerId: UUID?
    @ObservationIgnored private let connectionManager: ConnectionManagerRouting

    // Live-state tracking
    @ObservationIgnored private var tasksLive = false
    @ObservationIgnored private var taskSubscriptionId: String?
    @ObservationIgnored private var taskReconciler: DeltaReconciler<WorkspaceTask>?
    @ObservationIgnored private var resnapshotInProgress = false

    init(workspaceId: String, connectionManager: ConnectionManagerRouting = ConnectionManager.shared) {
        self.workspaceId = workspaceId
        self.connectionManager = connectionManager

        connectionManager.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state == .connected {
                    Task { await self?.onConnected() }
                }
            }
            .store(in: &cancellables)
    }

    isolated deinit {
        // Remove handlers directly while deinit is isolated to MainActor.
        guard eventHandlerId != nil || taskSubscriptionId != nil else { return }
        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
        }
        if let subscriptionId = taskSubscriptionId {
            connectionManager.unregisterSubscriptionHandler(id: subscriptionId)
        }
    }

    private func onConnected() async {
        // Reset live-state tracking on new connection
        tasksLive = false
        // Unregister old handler if reconnecting (defensive: subscription is invalid after disconnect)
        if let oldId = taskSubscriptionId {
            connectionManager.unregisterSubscriptionHandler(id: oldId)
        }
        taskSubscriptionId = nil
        taskReconciler = nil
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
            let result = try await connectionManager.request("task.list", params: [
                "workspaceId": workspaceId
            ])
            if let dict = result as? [String: Any],
               let tasksArray = dict["tasks"] as? [[String: Any]] {
                tasks = tasksArray.compactMap { WorkspaceTask.parseTask($0) }
                lastUpdated = Date()
            }
        } catch {
            AppLog.tasks.error("[TaskStore] Failed to fetch tasks: \(error)")
        }
        isLoading = false
    }

    // MARK: - Event subscription

    private func subscribeToEvents() async {
        // Remove old handler to prevent accumulation on reconnect
        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
        }

        // Register event handler on ConnectionManager
        eventHandlerId = connectionManager.onEvent { [weak self] method, params in
            Task { @MainActor in
                self?.handleEvent(method, params: params)
            }
        }
    }

    private func subscribeLiveState() async {
        // Initialize task reconciler
        taskReconciler = DeltaReconciler<WorkspaceTask>(
            getId: { dict in dict["id"] as? String },
            normalize: { dict in WorkspaceTask.parseTask(dict) }
        )

        // Try to subscribe - if server doesn't support it, error response falls back to legacy
        do {
            let result = try await connectionManager.request("task.subscribe", params: [
                "workspaceId": workspaceId,
                "replaceGroup": "ios-tasks-\(workspaceId)"
            ])
            if let dict = result as? [String: Any],
               let subId = dict["subscriptionId"] as? String {
                // Unregister old handler if we had one
                if let oldId = taskSubscriptionId {
                    connectionManager.unregisterSubscriptionHandler(id: oldId)
                }
                taskSubscriptionId = subId
                // Register handler immediately in same MainActor tick (preserves sync-capture guarantee)
                connectionManager.registerSubscriptionHandler(id: subId) { [weak self] push in
                    self?.handleSubscriptionPush(push)
                }
                AppLog.tasks.debug("[TaskStore] Subscribed to task.subscribe: \(subId)")
            } else {
                // Response missing subscriptionId - clean up and fall back to legacy
                taskReconciler = nil
                taskSubscriptionId = nil
            }
        } catch {
            // Subscribe failed - clean up reconciler and fall back to legacy
            taskReconciler = nil
            taskSubscriptionId = nil
            AppLog.tasks.error("[TaskStore] task.subscribe failed: \(error), falling back to legacy")
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

        // Scope task:* events to this workspace to avoid cross-workspace refetches
        let eventWorkspaceId = event["workspaceId"] as? String
        guard eventWorkspaceId == workspaceId else { return }

        // Explicit allowlist (mirrors AgentStore / WorkspaceStore): only events
        // that can change a field a `WorkspaceTask` row renders (id, title,
        // status, updatedAt) refetch `task.list`. `task:created` changes list
        // membership; `task:status-changed` changes status/updatedAt.
        //
        // Deliberately excluded: `task:ready-tasks-changed` — readiness is not
        // rendered, and its status-change emissions always pair with a
        // `task:status-changed` that already refetches (its relation-change /
        // note-deleted emissions carry no rendered field); `task:agent-linked`
        // / `task:agent-unlinked` — the assignee is not part of the row. Task
        // body/title edits ride `note:updated`, not `task:*`, so they never
        // reached this store either way.
        //
        // The refetch runs only in the non-live fallback (no `task.subscribe`
        // snapshot yet, or after a subscription loss); while live, deltas
        // arrive via the subscription push and a refetch would double-apply.
        switch eventType {
        case "task:created", "task:status-changed":
            if !tasksLive {
                Task { await fetchAll() }
            }
        default:
            break
        }
    }

    private func handleSubscriptionPush(_ push: SubscriptionPush) {
        // Only process pushes if we have a reconciler ready
        // (reconciler is initialized synchronously before subscribe request, so any
        // push arriving between subscribe-sent and response-received is safe to process)
        guard let reconciler = taskReconciler else {
            return
        }

        // ConnectionManager now routes pushes by subscriptionId at the transport layer,
        // so this handler only receives pushes for our exact subscriptionId.
        // No per-store gate needed (single source of truth is the router)

        switch push.kind {
        case .snapshot:
            guard let rawItems = push.snapshot else { return }
            tasksLive = true
            reconciler.applySnapshot(seq: push.seq, rawItems: rawItems)
            tasks = reconciler.values()
            lastUpdated = Date()
            AppLog.tasks.debug("[TaskStore] Applied snapshot with \(rawItems.count) tasks, seq=\(push.seq)")

        case .delta:
            guard let delta = push.delta else { return }
            if reconciler.applyDelta(seq: push.seq, delta: delta) {
                tasks = reconciler.values()
                lastUpdated = Date()
                AppLog.tasks.debug("[TaskStore] Applied delta seq=\(push.seq), added=\(delta.added.count), updated=\(delta.updated.count), removed=\(delta.removedIds.count)")
            } else {
                // Gap detected — resnapshot (guard against storm)
                if !resnapshotInProgress {
                    resnapshotInProgress = true
                    AppLog.tasks.warning("[TaskStore] Sequence gap detected at seq=\(push.seq), resubscribing...")
                    Task { await resnapshot() }
                }
            }
        }
    }

    private func resnapshot() async {
        resnapshotInProgress = true
        defer { resnapshotInProgress = false }

        tasksLive = false
        taskReconciler?.reset()

        if let subId = taskSubscriptionId {
            // Unregister handler before unsubscribing
            connectionManager.unregisterSubscriptionHandler(id: subId)
            do {
                let _ = try await connectionManager.request("task.unsubscribe", params: [
                    "subscriptionId": subId
                ])
            } catch {
                AppLog.tasks.error("[TaskStore] task.unsubscribe failed: \(error)")
            }
        }

        taskSubscriptionId = nil
        await subscribeLiveState()
        // Baseline refetch to bridge the gap during resnapshot
        await fetchAll()
    }
}
