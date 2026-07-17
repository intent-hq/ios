import Foundation
import Combine

/// ObservableObject managing task state for a single workspace
@MainActor
class TaskStore: ObservableObject {
    @Published var tasks: [Task] = []
    @Published var isLoading = false
    @Published var lastUpdated: Date?

    private var workspaceId: String
    private var cancellables = Set<AnyCancellable>()
    private var eventHandlerId: UUID?

    // Live-state tracking
    private var tasksLive = false
    private var taskSubscriptionId: String?
    private var taskReconciler: DeltaReconciler<Task>?
    private var resnapshotInProgress = false

    init(workspaceId: String) {
        self.workspaceId = workspaceId

        ConnectionManager.shared.$connectionState
            .sink { [weak self] state in
                if state == .connected {
                    Task { await self?.onConnected() }
                }
            }
    }

    private func onConnected() async {
        // Reset live-state tracking on new connection
        tasksLive = false
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
            let result = try await ConnectionManager.shared.request("task.list", params: [
                "workspaceId": workspaceId
            ])
            if let dict = result as? [String: Any],
               let tasksArray = dict["tasks"] as? [[String: Any]] {
                tasks = tasksArray.compactMap { Task.parseTask($0) }
                lastUpdated = Date()
            }
        } catch {
            print("[TaskStore] Failed to fetch tasks: \(error)")
        }
        isLoading = false
    }

    // MARK: - Event subscription

    private func subscribeToEvents() async {
        // Remove old handler to prevent accumulation on reconnect
        if let handlerId = eventHandlerId {
            ConnectionManager.shared.removeEventHandler(id: handlerId)
        }

        // Register event handler on ConnectionManager
        eventHandlerId = ConnectionManager.shared.onEvent { [weak self] method, params in
            Task { @MainActor in
                self?.handleEvent(method, params: params)
            }
        }
    }

    private func subscribeLiveState() async {
        // Initialize task reconciler
        taskReconciler = DeltaReconciler<Task>(
            getId: { dict in dict["id"] as? String },
            normalize: { dict in Task.parseTask(dict) }
        )

        // Try to subscribe - if server doesn't support it, error response falls back to legacy
        do {
            let result = try await ConnectionManager.shared.request("task.subscribe", params: [
                "workspaceId": workspaceId,
                "replaceGroup": "ios-tasks-\(workspaceId)"
            ])
            if let dict = result as? [String: Any],
               let subId = dict["subscriptionId"] as? String {
                taskSubscriptionId = subId
                print("[TaskStore] Subscribed to task.subscribe: \(subId)")
            }
        } catch {
            print("[TaskStore] task.subscribe failed: \(error), falling back to legacy")
        }
    }

    func handleEvent(_ method: String, params: Any) {
        // Handle subscription.push for live-state updates
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

        // Only refetch if not in live mode (avoid double-apply)
        if eventType.hasPrefix("task:") && !tasksLive {
            Task { await fetchAll() }
        }
    }

    private func handleSubscriptionPush(_ push: SubscriptionPush) {
        // Only process pushes if we have a reconciler ready
        // (reconciler is initialized synchronously before subscribe request, so any
        // push arriving between subscribe-sent and response-received is safe to process)
        guard let reconciler = taskReconciler else {
            return
        }

        // Log subscriptionId mismatch if we already have one (sanity check, not a gate)
        if let subId = taskSubscriptionId, push.subscriptionId != subId {
            print("[TaskStore] Warning: received push for subscription \(push.subscriptionId), expected \(subId)")
        }

        switch push.kind {
        case .snapshot:
            guard let rawItems = push.snapshot else { return }
            tasksLive = true
            reconciler.applySnapshot(seq: push.seq, rawItems: rawItems)
            tasks = reconciler.values()
            lastUpdated = Date()
            print("[TaskStore] Applied snapshot with \(rawItems.count) tasks, seq=\(push.seq)")

        case .delta:
            guard let delta = push.delta else { return }
            if reconciler.applyDelta(seq: push.seq, delta: delta) {
                tasks = reconciler.values()
                lastUpdated = Date()
                print("[TaskStore] Applied delta seq=\(push.seq), added=\(delta.added.count), updated=\(delta.updated.count), removed=\(delta.removedIds.count)")
            } else {
                // Gap detected — resnapshot (guard against storm)
                if !resnapshotInProgress {
                    resnapshotInProgress = true
                    print("[TaskStore] Sequence gap detected at seq=\(push.seq), resubscribing...")
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
            do {
                let _ = try await ConnectionManager.shared.request("task.unsubscribe", params: [
                    "subscriptionId": subId
                ])
            } catch {
                print("[TaskStore] task.unsubscribe failed: \(error)")
            }
        }

        taskSubscriptionId = nil
        await subscribeLiveState()
    }
}
