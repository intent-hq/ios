import Combine
import Foundation
import Observation

@MainActor
@Observable class WorkspaceStore {
    static let shared = WorkspaceStore()

    var workspaces: [Workspace] = [] {
        didSet { workspacesRevision &+= 1 }
    }
    /// Invalidates derived lists for replacements and in-place array mutations.
    private(set) var workspacesRevision: UInt64 = 0
    var lastUpdated: Date?
    var isLoading = false
    var showArchived = false
    private(set) var updatingWorkspaceIDs: Set<String> = []
    var agentSummaries: AgentSummaryStore? {
        didSet {
            if let agentSummaries { agentSummaries.seedWorkspaces(workspaces, since: agentSummaries.beginRead()) }
        }
    }

    /// Ids this backend reported deleted or archived (events or own actions);
    /// unique across daemons, so consumers need not know which daemon replied.
    var removedWorkspaceIds: AnyPublisher<String, Never> { removedWorkspaceSubject.eraseToAnyPublisher() }
    @ObservationIgnored private let removedWorkspaceSubject = PassthroughSubject<String, Never>()
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private var fetchRevision = 0
    @ObservationIgnored private var fetchNeedsRefresh = false
    @ObservationIgnored private var connectionObserver: AnyCancellable?
    @ObservationIgnored private var eventHandlerId: UUID?
    @ObservationIgnored private let connectionManager: ConnectionManagerRouting

    // Live-state subscription tracking
    @ObservationIgnored private var workspaceSubscriptionId: String?
    /// Read-only outside this file so local patches can reseed it.
    @ObservationIgnored private(set) var workspaceReconciler: DeltaReconciler<Workspace>?
    @ObservationIgnored private var workspaceLive = false
    @ObservationIgnored private var resnapshotInProgress = false
    /// Reads the rest of a paged `workspace.subscribe` snapshot (protocol §6.9).
    @ObservationIgnored let snapshotFiller = PagedSnapshotFiller()

    /// Each pinned backend session owns a store over its own connection.
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
        snapshotFiller.cancel()
        resnapshotInProgress = false

        await fetchAll()
        subscribeToEvents()
        await subscribeLiveState()
    }

    // MARK: - Fetch

    func fetchIfNeeded() async {
        guard lastUpdated == nil || fetchNeedsRefresh else { return }
        await fetchAll()
    }

    func fetchAll() async {
        await startFetch().value
    }

    func perform(_ action: WorkspaceAction, workspaceId: String) async throws {
        guard updatingWorkspaceIDs.insert(workspaceId).inserted else { return }
        defer { updatingWorkspaceIDs.remove(workspaceId) }
        let result = try await connectionManager.request(action.method, params: ["workspaceId": workspaceId])
        let response = result as? [String: Any]
        let succeeded: Bool
        switch action {
        case .archive:
            let workspace = response?["workspace"] as? [String: Any]
            succeeded = workspace?["id"] as? String == workspaceId
                && (workspace?["status"] as? String)?.lowercased() == "archived"
        case .delete:
            succeeded = response?["success"] as? Bool == true
        }
        guard succeeded else {
            throw NSError(domain: "WorkspaceAction", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The server did not confirm the workspace \(action.rawValue). Please try again."
            ])
        }
        workspaces.removeAll { $0.id == workspaceId }
        removedWorkspaceSubject.send(workspaceId)
        invalidateFetchForEvent()
        await fetchAll()
    }

    private func startFetch() -> Task<Void, Never> {
        if let fetchTask { return fetchTask }
        let task = Task { await self._fetchAll() }
        fetchTask = task
        return task
    }

    private func invalidateFetchForEvent() {
        fetchRevision &+= 1
        fetchNeedsRefresh = true
        _ = startFetch()
    }

    private func _fetchAll() async {
        fetchNeedsRefresh = true
        isLoading = true
        var needsSuccessor = false
        defer {
            // Retire this owner before handing off or announcing idle. Passive
            // callers join the successor; completion observers may start anew.
            fetchTask = nil
            if needsSuccessor {
                _ = startFetch()
            } else {
                isLoading = false
            }
        }
        // Passive callers share this owner. Events during a read invalidate
        // its snapshot and coalesce into one trailing read. An event during
        // that read belongs to one successor, keeping the list loading until
        // events settle. Failure alone stays dirty without automatic retries.
        for round in 0..<2 {
            let revision = fetchRevision
            do {
                let summaryBoundary = agentSummaries?.beginRead()
                let rows = try await requestAllWorkspaceRows()
                if revision == fetchRevision {
                    fetchNeedsRefresh = false
                    publishFetchedWorkspaces(rows.compactMap { Self.parseWorkspace($0) }, summaryBoundary: summaryBoundary)
                    return
                }
            } catch {
                AppLog.workspace.error("[WorkspaceStore] Failed to fetch workspaces: \(error)")
            }
            guard revision != fetchRevision else { return }
            needsSuccessor = round == 1
        }
    }

    /// Every `workspace.list` page (protocol "Paged workspace lists": `limit`
    /// + `nextToken`, rows in `(createdAt, id)` order). A daemon without paging
    /// answers the whole list in one reply, possibly as a bare array. A failed
    /// page fails the whole read, so a partial list is never published as
    /// whole (a missing row would read as a deleted workspace).
    private func requestAllWorkspaceRows() async throws -> [[String: Any]] {
        try await PagedReads.requestAllPages(
            params: ["includeArchived": true, "limit": PagedReads.workspacePageLimit],
            field: "workspaces"
        ) { [connectionManager] params in
            let reply = try await connectionManager.request("workspace.list", params: params)
            if let rows = reply as? [[String: Any]] { return ["workspaces": rows] }
            return reply
        }
    }

    /// Publishes a fetched workspace list. `lastUpdated` is set **before** `workspaces`
    /// so observers that gate on "fetched at least once" (e.g. AppCoordinator's
    /// missing-workspace validation) see a non-nil `lastUpdated` on the very first
    /// post-fetch change.
    func publishFetchedWorkspaces(_ parsed: [Workspace], summaryBoundary: AgentSummaryStore.ReadBoundary? = nil) {
        if let agentSummaries {
            let changed = parsed.filter { incoming in
                summaryBoundary != nil
                    || workspaces.first { $0.id == incoming.id }?.agentSummaryAgents != incoming.agentSummaryAgents
                    || incoming.agentSummaryAgents.contains { agentSummaries.cached(agentId: $0.id).isEmpty }
            }
            agentSummaries.seedWorkspaces(changed, since: summaryBoundary ?? agentSummaries.beginRead())
        }
        lastUpdated = Date()
        workspaces = parsed
    }

    // MARK: - Upsert

    /// Upserts a row and seeds the live reconciler, excluding the virtual workspace.
    func addOrUpdate(_ workspace: Workspace) {
        guard workspace.id != Workspace.chiefWorkspaceId else { return }
        if let index = workspaces.firstIndex(where: { $0.id == workspace.id }) {
            workspaces[index] = workspace
        } else {
            workspaces.insert(workspace, at: 0)
        }
        workspaceReconciler?.seed(id: workspace.id, value: workspace)
    }

    func applyConfirmedTitle(_ title: String, workspaceId: String) {
        guard var workspace = workspaces.first(where: { $0.id == workspaceId }) else { return }
        workspace.title = title
        if snapshotFiller.isFilling, let index = workspaces.firstIndex(where: { $0.id == workspaceId }) {
            // The published row is from the previous list; patch the fresher reconciler row.
            workspaces[index] = workspace
            workspaceReconciler?.patch(id: workspaceId) { row in
                var renamed = row
                renamed.title = title
                return renamed
            }
        } else {
            addOrUpdate(workspace)
        }
        invalidateFetchForEvent()
    }
}

extension WorkspaceStore {
    // MARK: - Event subscription

    private func subscribeToEvents() {
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

        guard let paramsDictionary = params as? [String: Any] else { return }
        let event = Self.eventDictionary(from: paramsDictionary)
        guard let eventType = event["type"] as? String else { return }
        AppLog.workspace.debug("[WorkspaceStore] Received event: \(eventType)")

        let eventWorkspaceId = event["workspaceId"] as? String
        let data = event["data"] as? [String: Any]

        if let removedId = Self.removedWorkspaceId(type: eventType, workspaceId: eventWorkspaceId, data: data ?? [:]) {
            removedWorkspaceSubject.send(removedId)
        }

        // In-place patches apply in every mode (live or not) and before the
        // refetch decision, since they are the complete application of the event.
        if eventType == "workspace:updated",
           let changes = data?["changes"] as? [String: Any],
           let lastActivity = changes["lastActivity"] as? String,
           let workspaceId = eventWorkspaceId {
            updateLastActivity(workspaceId: workspaceId, lastActivity: lastActivity)
        }
        if eventType == "workspace:waiting-changed",
           let data,
           let waiting = data["waiting"] as? Bool,
           let workspaceId = (data["workspaceId"] as? String) ?? eventWorkspaceId {
            updateWaiting(workspaceId: workspaceId, waiting: waiting)
        }

        switch Self.classify(type: eventType, data: data) {
        case .refetch:
            if !workspaceLive || eventType == "host:members-changed" {
                invalidateFetchForEvent()
            }
        case .patchInPlace, .ignore:
            break
        case nil:
            AppLog.workspace.debug("[WorkspaceStore] Ignoring unclassified event: \(eventType)")
        }
    }

    /// Unwraps the websocket-event-bridge envelope while preserving direct
    /// event dictionaries used by tests and legacy callers.
    private static func eventDictionary(from dictionary: [String: Any]) -> [String: Any] {
        (dictionary["event"] as? [String: Any]) ?? dictionary
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
            AppLog.workspace.debug("[WorkspaceStore] Applied snapshot with \(rawItems.count) workspaces, seq=\(push.seq)")
            if let token = push.nextToken {
                fillSnapshot(reconciler: reconciler, firstToken: token)
            } else {
                snapshotFiller.cancel()
                publishFetchedWorkspaces(reconciler.values())
            }

        case .delta:
            guard let delta = push.delta else { return }
            if reconciler.applyDelta(seq: push.seq, delta: delta) {
                // A paged snapshot still filling publishes once complete.
                if !snapshotFiller.isFilling { publishFetchedWorkspaces(reconciler.values()) }
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

    /// Reads the rest of a paged snapshot (§6.9) with `workspace.list`, then
    /// publishes the whole list. A partial list is never published: views
    /// treat a workspace missing from a loaded list as deleted. A walk that
    /// gives up keeps the previous list and resubscribes.
    private func fillSnapshot(reconciler: DeltaReconciler<Workspace>, firstToken: String) {
        let source = PagedReads.PageSource(field: "workspaces") { [connectionManager] token in
            try await connectionManager.request("workspace.list", params: ["includeArchived": true, "nextToken": token])
        }
        snapshotFiller.start(reconciler, from: firstToken, source: source, owner: .init(
            isCurrent: { [weak self] in self?.workspaceReconciler === reconciler },
            publish: { [weak self] complete in
                if complete { self?.publishFetchedWorkspaces(reconciler.values()) }
            },
            resubscribe: { [weak self] in
                guard let self, !resnapshotInProgress else { return }
                await resnapshot()
            }
        ))
    }

    private func resnapshot() async {
        resnapshotInProgress = true
        defer { resnapshotInProgress = false }

        workspaceLive = false
        workspaceReconciler?.reset()
        snapshotFiller.cancel()

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
}
