import Combine
import Foundation
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
    @ObservationIgnored private var liveSubscription = LiveSubscription.idle
    @ObservationIgnored private var taskReconciler: DeltaReconciler<WorkspaceTask>?
    /// Reads the rest of a paged `task.subscribe` snapshot (§6.9).
    @ObservationIgnored let snapshotFiller = PagedSnapshotFiller()

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
        guard eventHandlerId != nil || liveSubscription.id != nil else { return }
        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
        }
        if let subscriptionId = liveSubscription.id {
            connectionManager.unregisterSubscriptionHandler(id: subscriptionId)
        }
    }

    private func onConnected() async {
        // Reset live-state tracking on new connection. Unregister the old
        // handler if reconnecting (defensive: subscription is invalid after disconnect)
        if let oldId = liveSubscription.reset() {
            connectionManager.unregisterSubscriptionHandler(id: oldId)
        }
        taskReconciler = nil
        snapshotFiller.cancel()

        await fetchAll()
        subscribeToEvents()
        await subscribeLiveState()
    }

    // MARK: - Fetch

    func fetchAll() async {
        await _fetchAll()
    }

    /// `task.list` without `limit` / `nextToken` answers the whole list; if a
    /// reply carries `nextToken` anyway, every page is read before publishing,
    /// and a failed page keeps the previous list (bounded reads).
    private func _fetchAll() async {
        isLoading = true
        do {
            let params: [String: Any] = ["workspaceId": workspaceId]
            let result = try await PagedReads.requestWholeReply(params: params, field: "tasks") { [connectionManager] page in
                try await connectionManager.request("task.list", params: page)
            }
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

    private func subscribeToEvents() {
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
                if let oldId = liveSubscription.acknowledge(subId) {
                    connectionManager.unregisterSubscriptionHandler(id: oldId)
                }
                // Register handler immediately in same MainActor tick (preserves sync-capture guarantee)
                connectionManager.registerSubscriptionHandler(id: subId) { [weak self] push in
                    self?.handleSubscriptionPush(push)
                }
                AppLog.tasks.debug("[TaskStore] Subscribed to task.subscribe: \(subId)")
            } else {
                // Response missing subscriptionId - clean up and fall back to legacy
                taskReconciler = nil
                liveSubscription.clearId()
            }
        } catch {
            // Subscribe failed - clean up reconciler and fall back to legacy
            taskReconciler = nil
            liveSubscription.clearId()
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

        // The refetch runs only in the non-live fallback (no `task.subscribe`
        // snapshot yet, or after a subscription loss); while live, deltas
        // arrive via the subscription push and a refetch would double-apply.
        switch Self.classify(type: eventType, data: event["data"] as? [String: Any]) {
        case .refetch:
            if !liveSubscription.isLive {
                Task { await fetchAll() }
            }
        case .patchInPlace, .ignore, nil:
            break
        }
    }

    // MARK: - Event classification

    /// Bus channels this store consumes. Every catalog type on them must be in
    /// exactly one table below (`IntentTests/EventCatalogCoverageTests.swift`).
    nonisolated static let handledChannels = ["task:"]

    /// Explicit allowlist (mirrors AgentStore / WorkspaceStore): only events
    /// that can change a field a `WorkspaceTask` row renders (id, title,
    /// status, updatedAt) or list membership refetch `task.list`.
    /// `task:created` changes membership; `task:status-changed` changes
    /// status/updatedAt.
    nonisolated static let refetchEventTypes: Set<String> = [
        "task:created", "task:status-changed"
    ]

    /// Deliberately ignored: `task:agent-linked` / `task:agent-unlinked` — the
    /// assignee is not part of the row. Task body/title edits ride
    /// `note:updated`, not `task:*`, so they never reached this store either
    /// way.
    nonisolated static let ignoredEventTypes: Set<String> = [
        "task:agent-linked", "task:agent-unlinked"
    ]

    /// `task:ready-tasks-changed` is classified per `data.triggeredBy.reason`
    /// (the golden's `discriminators` entry for this type). Readiness is not
    /// rendered: `relations-changed` emissions carry no rendered field —
    /// except `note-deleted`: intentd's `delete_note` emits no other `task:*`
    /// type (only `note:deleted`, which this store does not receive), so that
    /// emission is the only `task:*` signal that a row left the list.
    nonisolated static let readyTasksChangedReasonClassification: [String: EventClassification] = [
        "note-deleted": .refetch,
        "relations-changed": .ignore
    ]

    /// The status-change emission has no `reason` (`triggeredBy` is
    /// `{ noteId, previousStatus, newStatus }`); it always pairs with a
    /// `task:status-changed` that already refetches.
    nonisolated static let readyTasksChangedWithoutReason: EventClassification = .ignore

    /// Pure classification of one event; `nil` means the tables above do not
    /// name the type (or, for `task:ready-tasks-changed`, the reason), which
    /// `handleEvent` treats as ignore.
    nonisolated static func classify(
        type: String,
        // The shared classifier signature accepts absent event data without inventing a payload.
        data: [String: Any]? // swiftlint:disable:this discouraged_optional_collection
    ) -> EventClassification? {
        if refetchEventTypes.contains(type) { return .refetch }
        if ignoredEventTypes.contains(type) { return .ignore }
        if type == "task:ready-tasks-changed" {
            let triggeredBy = data?["triggeredBy"] as? [String: Any]
            guard let reason = triggeredBy?["reason"] as? String else {
                return readyTasksChangedWithoutReason
            }
            return readyTasksChangedReasonClassification[reason]
        }
        return nil
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
            liveSubscription.applySnapshot()
            reconciler.applySnapshot(seq: push.seq, rawItems: rawItems)
            AppLog.tasks.debug("[TaskStore] Applied snapshot with \(rawItems.count) tasks, seq=\(push.seq)")
            if let token = push.nextToken {
                fillSnapshot(reconciler: reconciler, firstToken: token)
            } else {
                snapshotFiller.cancel()
                tasks = reconciler.values()
                lastUpdated = Date()
            }

        case .delta:
            guard let delta = push.delta else { return }
            if reconciler.applyDelta(seq: push.seq, delta: delta) {
                // A paged snapshot still filling publishes once complete.
                if !snapshotFiller.isFilling {
                    tasks = reconciler.values()
                    lastUpdated = Date()
                }
                AppLog.tasks.debug("[TaskStore] Applied delta seq=\(push.seq), added=\(delta.added.count), updated=\(delta.updated.count), removed=\(delta.removedIds.count)")
            } else {
                // Gap detected — resnapshot (guard against storm)
                if liveSubscription.requestResnapshot() {
                    AppLog.tasks.warning("[TaskStore] Sequence gap detected at seq=\(push.seq), resubscribing...")
                    Task { await resnapshot() }
                }
            }
        }
    }

    /// Reads the rest of a paged snapshot (§6.9) through the paged `task.list`
    /// (`WorkspaceTask` rows, which parse like the snapshot's task notes), then
    /// publishes the whole list; the previous list stays visible meanwhile.
    /// A walk that gives up shows what it has unless that would shrink the
    /// list, then resubscribes.
    private func fillSnapshot(reconciler: DeltaReconciler<WorkspaceTask>, firstToken: String) {
        let workspaceId = workspaceId
        let source = PagedReads.PageSource(field: "tasks") { [connectionManager] token in
            try await connectionManager.request("task.list", params: [
                "workspaceId": workspaceId, "limit": PagedReads.taskPageLimit, "nextToken": token
            ])
        }
        snapshotFiller.start(reconciler, from: firstToken, source: source, owner: .init(
            isCurrent: { [weak self] in self?.taskReconciler === reconciler },
            publish: { [weak self] complete in
                guard let self, complete || reconciler.values().count >= tasks.count else { return }
                tasks = reconciler.values()
                lastUpdated = Date()
            },
            resubscribe: { [weak self] in
                guard let self, !liveSubscription.isResnapshotting else { return }
                await resnapshot()
            }
        ))
    }

    private func resnapshot() async {
        liveSubscription.beginResnapshot()
        defer { liveSubscription.endResnapshot() }

        taskReconciler?.reset()
        snapshotFiller.cancel()

        if let subId = liveSubscription.id {
            // Unregister handler before unsubscribing
            connectionManager.unregisterSubscriptionHandler(id: subId)
            do {
                _ = try await connectionManager.request("task.unsubscribe", params: [
                    "subscriptionId": subId
                ])
            } catch {
                AppLog.tasks.error("[TaskStore] task.unsubscribe failed: \(error)")
            }
        }

        liveSubscription.clearId()
        await subscribeLiveState()
        // Baseline refetch to bridge the gap during resnapshot
        await fetchAll()
    }
}
