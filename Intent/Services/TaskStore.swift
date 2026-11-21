import Combine
import Foundation
import Observation

@MainActor
@Observable class TaskStore {
    var tasks: [WorkspaceTask] = []
    var isLoading = false
    var lastUpdated: Date?

    @ObservationIgnored private var workspaceId: String
    @ObservationIgnored private var fetchRevision = 0
    @ObservationIgnored let eventRefreshes = CoalescedRead()
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var eventHandlerId: UUID?
    @ObservationIgnored private let connectionManager: ConnectionManagerRouting

    @ObservationIgnored private var liveSubscription = LiveSubscription.idle
    @ObservationIgnored private var liveSubscriptionGeneration = 0
    @ObservationIgnored private var taskReconciler: DeltaReconciler<WorkspaceTask>?
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
        eventRefreshes.cancel()
        guard eventHandlerId != nil || liveSubscription.id != nil else { return }
        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
        }
        if let subscriptionId = liveSubscription.id {
            connectionManager.unregisterSubscriptionHandler(id: subscriptionId)
        }
    }

    private func onConnected() async {
        liveSubscriptionGeneration &+= 1
        if let oldId = liveSubscription.reset() {
            connectionManager.unregisterSubscriptionHandler(id: oldId)
        }
        taskReconciler = nil
        snapshotFiller.cancel()

        let generation = liveSubscriptionGeneration
        await fetchAll()
        subscribeToEvents()
        guard generation == liveSubscriptionGeneration else { return }
        await subscribeLiveState(generation: generation)
    }

    // MARK: - Fetch

    func fetchAll() async {
        await _fetchAll()
    }

    private func _fetchAll() async {
        guard !Task.isCancelled else { return }
        fetchRevision &+= 1
        let requestRevision = fetchRevision
        isLoading = true
        defer {
            if fetchRevision == requestRevision { isLoading = false }
        }
        do {
            let params: [String: Any] = ["workspaceId": workspaceId]
            let result = try await PagedReads.requestWholeReply(params: params, field: "tasks") { [connectionManager] page in
                try await connectionManager.request("task.list", params: page)
            }
            guard fetchRevision == requestRevision else { return }
            try Task.checkCancellation()
            if let dict = result as? [String: Any],
               let tasksArray = dict["tasks"] as? [[String: Any]] {
                tasks = tasksArray.compactMap { WorkspaceTask.parseTask($0) }
                lastUpdated = Date()
            }
        } catch is CancellationError {
        } catch {
            AppLog.tasks.error("[TaskStore] Failed to fetch tasks: \(error)")
        }
    }

    // MARK: - Event subscription

    private func subscribeToEvents() {
        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
        }

        eventHandlerId = connectionManager.onEvent { [weak self] method, params in
            Task { @MainActor in
                self?.handleEvent(method, params: params)
            }
        }
    }

    private func subscribeLiveState(generation: Int) async {
        taskReconciler = DeltaReconciler<WorkspaceTask>(
            getId: { dict in dict["id"] as? String },
            normalize: { dict in WorkspaceTask.parseTask(dict) }
        )

        do {
            let result = try await connectionManager.request("task.subscribe", params: [
                "workspaceId": workspaceId,
                "replaceGroup": "ios-tasks-\(workspaceId)"
            ])
            guard generation == liveSubscriptionGeneration else {
                if let dict = result as? [String: Any], let subId = dict["subscriptionId"] as? String,
                   connectionManager.connectionState == .connected {
                    _ = try? await connectionManager.request("task.unsubscribe", params: ["subscriptionId": subId])
                }
                return
            }
            if let dict = result as? [String: Any],
               let subId = dict["subscriptionId"] as? String {
                if let oldId = liveSubscription.acknowledge(subId) {
                    connectionManager.unregisterSubscriptionHandler(id: oldId)
                }
                connectionManager.registerSubscriptionHandler(id: subId) { [weak self] push in
                    self?.handleSubscriptionPush(push)
                }
                AppLog.tasks.debug("[TaskStore] Subscribed to task.subscribe: \(subId)")
            } else {
                taskReconciler = nil
                liveSubscription.clearId()
            }
        } catch {
            guard generation == liveSubscriptionGeneration else { return }
            taskReconciler = nil
            liveSubscription.clearId()
            AppLog.tasks.error("[TaskStore] task.subscribe failed: \(error), falling back to legacy")
        }
    }

    func handleEvent(_ method: String, params: Any) {
        if let push = SubscriptionPush.parse(method: method, params: params) {
            handleSubscriptionPush(push)
            return
        }

        guard let dict = params as? [String: Any] else { return }

        let event: [String: Any]
        if let innerEvent = dict["event"] as? [String: Any] {
            event = innerEvent
        } else {
            event = dict
        }

        guard let eventType = event["type"] as? String else { return }

        let eventWorkspaceId = event["workspaceId"] as? String
        guard eventWorkspaceId == workspaceId else { return }

        switch Self.classify(type: eventType, data: event["data"] as? [String: Any]) {
        case .refetch:
            if !liveSubscription.isLive {
                queueEventRefresh()
            }
        case .patchInPlace, .ignore, nil:
            break
        }
    }

    private func queueEventRefresh() {
        guard eventRefreshes.invalidate() else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            while await eventRefreshes.run(
                isCurrent: { [weak self] in self?.liveSubscription.isLive == false },
                pass: { [weak self] _ in await self?.fetchAll() }
            ) {}
        }
    }

    // MARK: - Event classification

    nonisolated static let handledChannels = ["task:"]

    nonisolated static let refetchEventTypes: Set<String> = [
        "task:created", "task:status-changed"
    ]

    nonisolated static let ignoredEventTypes: Set<String> = [
        "task:agent-linked", "task:agent-unlinked"
    ]

    nonisolated static let readyTasksChangedReasonClassification: [String: EventClassification] = [
        "note-deleted": .refetch,
        "relations-changed": .ignore
    ]

    nonisolated static let readyTasksChangedWithoutReason: EventClassification = .ignore

    nonisolated static func classify(
        type: String,
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
        guard let reconciler = taskReconciler else {
            return
        }

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
                if !snapshotFiller.isFilling {
                    tasks = reconciler.values()
                    lastUpdated = Date()
                }
                AppLog.tasks.debug("[TaskStore] Applied delta seq=\(push.seq), added=\(delta.added.count), updated=\(delta.updated.count), removed=\(delta.removedIds.count)")
            } else {
                if liveSubscription.requestResnapshot() {
                    AppLog.tasks.warning("[TaskStore] Sequence gap detected at seq=\(push.seq), resubscribing...")
                    Task { await resnapshot() }
                }
            }
        }
    }

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
        let generation = liveSubscriptionGeneration
        liveSubscription.beginResnapshot()
        defer {
            if generation == liveSubscriptionGeneration {
                liveSubscription.endResnapshot()
            }
        }

        taskReconciler?.reset()
        snapshotFiller.cancel()

        if let subId = liveSubscription.id {
            connectionManager.unregisterSubscriptionHandler(id: subId)
            do {
                _ = try await connectionManager.request("task.unsubscribe", params: [
                    "subscriptionId": subId
                ])
            } catch {
                AppLog.tasks.error("[TaskStore] task.unsubscribe failed: \(error)")
            }
        }

        guard generation == liveSubscriptionGeneration else { return }
        liveSubscription.clearId()
        await subscribeLiveState(generation: generation)
        guard generation == liveSubscriptionGeneration else { return }
        await fetchAll()
    }
}
