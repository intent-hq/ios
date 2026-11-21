import Combine
import Foundation
import Observation

@MainActor
@Observable class WorkspaceStore {
    static let shared = WorkspaceStore()

    var workspaces: [Workspace] = [] {
        didSet { workspacesRevision &+= 1 }
    }
    private(set) var workspacesRevision: UInt64 = 0
    var loadPhase = LoadPhase.idle
    var lastUpdated: Date? { loadPhase.lastLoadedAt }
    var isLoading: Bool { loadPhase.isLoading }
    var showArchived = false
    private(set) var updatingWorkspaceIDs: Set<String> = []
    var agentSummaries: AgentSummaryStore? {
        didSet {
            if let agentSummaries { agentSummaries.seedWorkspaces(workspaces, since: agentSummaries.beginRead()) }
        }
    }

    var removedWorkspaceIds: AnyPublisher<String, Never> { removedWorkspaceSubject.eraseToAnyPublisher() }
    @ObservationIgnored private let removedWorkspaceSubject = PassthroughSubject<String, Never>()
    @ObservationIgnored let fetchReads = CoalescedRead()
    @ObservationIgnored private var fetchedRevision: Int? = 0
    @ObservationIgnored private var connectionObserver: AnyCancellable?
    @ObservationIgnored private var eventHandlerId: UUID?
    @ObservationIgnored private let connectionManager: ConnectionManagerRouting

    @ObservationIgnored private var liveSubscription = LiveSubscription.idle
    @ObservationIgnored private var liveSubscriptionGeneration = 0
    @ObservationIgnored private(set) var workspaceReconciler: DeltaReconciler<Workspace>?
    @ObservationIgnored let snapshotFiller = PagedSnapshotFiller()

    init(connectionManager: ConnectionManagerRouting = ConnectionManager.shared) {
        self.connectionManager = connectionManager
        observeConnection()
    }

    init(forTesting _: Bool) {
        self.connectionManager = ConnectionManager.shared
    }

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
        liveSubscriptionGeneration &+= 1
        if let oldId = liveSubscription.reset() {
            connectionManager.unregisterSubscriptionHandler(id: oldId)
        }
        workspaceReconciler = nil
        snapshotFiller.cancel()

        await fetchAll()
        subscribeToEvents()
        await subscribeLiveState(generation: liveSubscriptionGeneration)
    }

    // MARK: - Fetch

    func fetchIfNeeded() async {
        guard lastUpdated == nil || fetchNeedsRefresh else { return }
        await fetchAll()
    }

    private var fetchNeedsRefresh: Bool { fetchedRevision != fetchReads.revision }

    func fetchAll() async {
        let lastPass = FetchPassOutcome()
        let needsSuccessor = await fetchReads.run { true } pass: { [weak self] revision in
            lastPass.error = await self?.fetchPass(revision)
        }
        if needsSuccessor {
            invalidateFetchForEvent()
        } else if fetchReads.phase == .idle {
            let next = lastPass.error.map { loadPhase.failing($0) } ?? loadPhase.settled()
            if next != loadPhase { loadPhase = next }
        }
    }

    @MainActor private final class FetchPassOutcome {
        var error: Error?
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

    private func invalidateFetchForEvent() {
        guard fetchReads.invalidate() else { return }
        Task { await fetchAll() }
    }

    private func fetchPass(_ revision: Int) async -> Error? {
        fetchedRevision = nil
        if !isLoading { loadPhase = loadPhase.beginning() }
        do {
            let summaryBoundary = agentSummaries?.beginRead()
            let rows = try await requestAllWorkspaceRows()
            guard revision == fetchReads.revision else { return nil }
            fetchedRevision = revision
            publishFetchedWorkspaces(rows.compactMap { Self.parseWorkspace($0) }, summaryBoundary: summaryBoundary)
            return nil
        } catch {
            AppLog.workspace.error("[WorkspaceStore] Failed to fetch workspaces: \(error)")
            return revision == fetchReads.revision ? error : nil
        }
    }

    func forgetPublishedWorkspaces() {
        workspaces = []
        loadPhase = isLoading ? .loading(lastLoadedAt: nil) : .idle
    }

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

    func publishFetchedWorkspaces(_ parsed: [Workspace], summaryBoundary: AgentSummaryStore.ReadBoundary? = nil) {
        if let agentSummaries {
            let changed = parsed.filter { incoming in
                summaryBoundary != nil
                    || workspaces.first { $0.id == incoming.id }?.agentSummaryAgents != incoming.agentSummaryAgents
                    || incoming.agentSummaryAgents.contains { agentSummaries.cached(agentId: $0.id).isEmpty }
            }
            agentSummaries.seedWorkspaces(changed, since: summaryBoundary ?? agentSummaries.beginRead())
        }
        loadPhase = isLoading ? .loading(lastLoadedAt: Date()) : .loaded(Date())
        workspaces = parsed
    }

    // MARK: - Upsert

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
        workspaceReconciler = DeltaReconciler<Workspace>(
            getId: { dict in dict["id"] as? String },
            normalize: { dict in Self.parseWorkspace(dict) }
        )

        do {
            let result = try await connectionManager.request("workspace.subscribe", params: [
                "replaceGroup": "ios-workspaces"
            ])
            guard generation == liveSubscriptionGeneration else {
                if let dict = result as? [String: Any], let subId = dict["subscriptionId"] as? String,
                   connectionManager.connectionState == .connected {
                    _ = try? await connectionManager.request("workspace.unsubscribe", params: ["subscriptionId": subId])
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
                AppLog.workspace.info("[WorkspaceStore] Subscribed to workspace.subscribe: \(subId)")
            }
        } catch {
            guard generation == liveSubscriptionGeneration else { return }
            AppLog.workspace.warning("[WorkspaceStore] workspace.subscribe failed: \(error), falling back to legacy")
        }
    }

    func handleEvent(_ method: String, params: Any) {
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
            if !liveSubscription.isLive || eventType == "host:members-changed" {
                invalidateFetchForEvent()
            }
        case .patchInPlace, .ignore:
            break
        case nil:
            AppLog.workspace.debug("[WorkspaceStore] Ignoring unclassified event: \(eventType)")
        }
    }

    private static func eventDictionary(from dictionary: [String: Any]) -> [String: Any] {
        (dictionary["event"] as? [String: Any]) ?? dictionary
    }

    private func handleSubscriptionPush(_ push: SubscriptionPush) {
        guard let reconciler = workspaceReconciler else {
            return
        }

        switch push.kind {
        case .snapshot:
            guard let rawItems = push.snapshot else { return }
            liveSubscription.applySnapshot()
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
                if !snapshotFiller.isFilling { publishFetchedWorkspaces(reconciler.values()) }
                AppLog.workspace.debug("[WorkspaceStore] Applied delta seq=\(push.seq), added=\(delta.added.count), updated=\(delta.updated.count), removed=\(delta.removedIds.count)")
            } else {
                if liveSubscription.requestResnapshot() {
                    AppLog.workspace.warning("[WorkspaceStore] Sequence gap detected at seq=\(push.seq), resubscribing...")
                    Task { await resnapshot() }
                }
            }
        }
    }

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

        workspaceReconciler?.reset()
        snapshotFiller.cancel()

        if let subId = liveSubscription.id {
            connectionManager.unregisterSubscriptionHandler(id: subId)
            do {
                _ = try await connectionManager.request("workspace.unsubscribe", params: [
                    "subscriptionId": subId
                ])
            } catch {
                AppLog.workspace.error("[WorkspaceStore] workspace.unsubscribe failed: \(error)")
            }
        }

        guard generation == liveSubscriptionGeneration else { return }
        liveSubscription.clearId()

        await subscribeLiveState(generation: generation)
        guard generation == liveSubscriptionGeneration else { return }
        await fetchAll()
    }
}
