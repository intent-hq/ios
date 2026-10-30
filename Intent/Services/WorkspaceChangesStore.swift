import Combine
import Foundation
import Observation

@MainActor
@Observable final class WorkspaceChangesStore {
    private(set) var stagedChanges: [WorkspaceChange] = []
    private(set) var unstagedChanges: [WorkspaceChange] = []
    private(set) var commits: [WorkspaceCommit] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var errorMessage: String?
    private(set) var isTruncated = false
    private(set) var isLoadingMore = false
    private(set) var roots: [WorkspaceGitRoot] = []
    private(set) var selectedRootId: String?
    private(set) var repositoryErrorMessage: String?
    var selectedRoot: WorkspaceGitRoot? { roots.first { $0.id == selectedRootId } }
    var hasMoreCommits: Bool { nextToken != nil }

    private var nextToken: String?
    @ObservationIgnored private var boundarySha: String?
    @ObservationIgnored private var workspaceId: String?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var registration = 0
    @ObservationIgnored private var isObserving = false
    @ObservationIgnored private var subscriptionId: String?
    @ObservationIgnored private var eventHandlerId: UUID?
    @ObservationIgnored private var refreshQueued = false
    @ObservationIgnored private var eventRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    let connectionManager: ConnectionManagerRouting
    private let replaceGroup = "ios-changes-\(UUID().uuidString)"
    private static let pageSize = 50

    init(connectionManager: ConnectionManagerRouting = ConnectionManager.shared) {
        self.connectionManager = connectionManager
        connectionManager.connectionStatePublisher
            .dropFirst()
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard state == .connected else { return }
                Task { @MainActor [weak self] in
                    guard let self, isObserving, let workspaceId else { return }
                    // Remote subscriptions do not survive a connection loss.
                    subscriptionId = nil
                    await startObserving(workspaceId: workspaceId)
                }
            }
            .store(in: &cancellables)
    }

    isolated deinit {
        eventRefreshTask?.cancel()
        if let eventHandlerId { connectionManager.removeEventHandler(id: eventHandlerId) }
        if let subscriptionId { Self.release(subscriptionId, via: connectionManager) }
    }

    /// Replaces both lists together. A later refresh, navigation, or change event invalidates the result.
    func refresh(workspaceId: String) async {
        guard !Task.isCancelled else { return }
        bind(workspaceId)
        revision &+= 1
        let requestRevision = revision
        isLoading = true
        isLoadingMore = false
        defer {
            if revision == requestRevision { isLoading = false }
        }
        await refreshRoots(workspaceId: workspaceId, requestRevision: requestRevision)
        guard owns(requestRevision), !Task.isCancelled else { return }
        let root = selectedRoot
        do {
            let snapshot = try await fetchChanges(workspaceId: workspaceId, root: root)
            guard owns(requestRevision), !Task.isCancelled else { return }
            let page = try await fetchCommits(workspaceId: workspaceId, root: root)
            guard owns(requestRevision), !Task.isCancelled else { return }
            stagedChanges = snapshot.changes.filter { $0.stage == "staged" }
            unstagedChanges = snapshot.changes.filter { $0.stage == "unstaged" }
            isTruncated = snapshot.isTruncated
            commits = Self.uniqueCommits(page.commits)
            nextToken = page.nextToken
            boundarySha = page.boundarySha
            errorMessage = nil
            hasLoaded = true
        } catch {
            guard owns(requestRevision), !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func selectRoot(id: String?) async {
        guard !Task.isCancelled, let workspaceId else { return }
        guard id == nil || roots.contains(where: { $0.id == id }) else {
            repositoryErrorMessage = "This repository is no longer available. Refresh the repository list."
            return
        }
        guard selectedRootId != id else { return }
        revision &+= 1
        selectedRootId = id
        refreshQueued = false
        clearRows()
        await refresh(workspaceId: workspaceId)
    }

    func loadMoreCommits() async {
        guard !Task.isCancelled, !isLoading, !isLoadingMore,
              let workspaceId, let token = nextToken else { return }
        let requestRevision = revision
        isLoadingMore = true
        defer {
            if revision == requestRevision { isLoadingMore = false }
        }
        do {
            let page = try await fetchCommits(workspaceId: workspaceId, root: selectedRoot, nextToken: token)
            guard owns(requestRevision), !Task.isCancelled else { return }
            // A rebase may move the boundary while a page is loading. Restart the bounded walk.
            guard page.boundarySha == boundarySha else {
                await refresh(workspaceId: workspaceId)
                return
            }
            guard page.nextToken != token else { throw WorkspaceChangesDecodingError.invalidCommits }
            commits = Self.uniqueCommits(commits + page.commits)
            nextToken = page.nextToken
            errorMessage = nil
        } catch {
            guard owns(requestRevision), !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func fetchChanges(workspaceId: String, root: WorkspaceGitRoot?) async throws -> WorkspaceChangesSnapshot {
        var params: [String: Any] = ["workspaceId": workspaceId]
        if let root {
            params["gitRootId"] = root.id
            params["forceRefresh"] = true
            let result = try await connectionManager.request("git.status", params: params)
            return try WorkspaceChangesSnapshot(result, rootId: root.id)
        }
        let result = try await connectionManager.request("file-tracking.getChanges", params: params)
        let tracked = try WorkspaceChangesSnapshot(result)
        params["forceRefresh"] = true
        let status = try await connectionManager.request("git.status", params: params)
        return try WorkspaceChangesSnapshot(status, rootId: "primary", trackedChanges: tracked.changes)
    }

    private func fetchCommits(
        workspaceId: String,
        root: WorkspaceGitRoot?,
        nextToken: String? = nil
    ) async throws -> WorkspaceCommitPage {
        var params: [String: Any] = [
            "workspaceId": workspaceId,
            "limit": Self.pageSize
        ]
        if let nextToken { params["nextToken"] = nextToken }
        if let root {
            params["gitRootId"] = root.id
            let result = try await connectionManager.request("git.commits", params: params)
            return try WorkspaceCommitPage(result, root: root)
        }
        params["includeOlder"] = false
        let result = try await connectionManager.request("file-tracking.loadCommits", params: params)
        return try WorkspaceCommitPage(result)
    }

    private static func uniqueCommits(_ commits: [WorkspaceCommit]) -> [WorkspaceCommit] {
        var hashes = Set<String>()
        return commits.filter { hashes.insert($0.hash).inserted }
    }

    private func owns(_ requestRevision: Int) -> Bool {
        workspaceId != nil && revision == requestRevision
    }

    private func bind(_ workspaceId: String) {
        guard self.workspaceId != workspaceId else { return }
        stopObserving()
        self.workspaceId = workspaceId
    }

    /// Invalidates pending reads synchronously so a disappearing screen cannot be repopulated.
    func stopObserving(preservingSnapshot: Bool = false) {
        registration &+= 1
        revision &+= 1
        isObserving = false
        eventRefreshTask?.cancel()
        eventRefreshTask = nil
        refreshQueued = false
        if let eventHandlerId { connectionManager.removeEventHandler(id: eventHandlerId) }
        eventHandlerId = nil
        if let subscriptionId { Self.release(subscriptionId, via: connectionManager) }
        subscriptionId = nil
        // A commit pushed over Changes keeps its repository and rows for Back.
        guard !preservingSnapshot else { return }
        workspaceId = nil
        roots = []
        selectedRootId = nil
        repositoryErrorMessage = nil
        clearRows()
    }

    private func clearRows() {
        stagedChanges = []
        unstagedChanges = []
        commits = []
        nextToken = nil
        boundarySha = nil
        isLoading = false
        isLoadingMore = false
        hasLoaded = false
        isTruncated = false
        errorMessage = nil
    }
}

extension WorkspaceChangesStore {
    /// Install the event handler before subscribing, then seed after the acknowledgement.
    func startObserving(workspaceId: String) async {
        guard !Task.isCancelled else { return }
        bind(workspaceId)
        registration &+= 1
        revision &+= 1
        let currentRegistration = registration
        eventRefreshTask?.cancel()
        eventRefreshTask = nil
        refreshQueued = false
        isLoading = true
        isLoadingMore = false
        isObserving = true
        if let eventHandlerId { connectionManager.removeEventHandler(id: eventHandlerId) }
        if let subscriptionId { Self.release(subscriptionId, via: connectionManager) }
        subscriptionId = nil
        eventHandlerId = connectionManager.onEvent { [weak self] _, params in
            Task { @MainActor [weak self] in
                guard let self, registration == currentRegistration else { return }
                handleEvent(params)
            }
        }
        await subscribe(workspaceId: workspaceId, registration: currentRegistration)
        guard registration == currentRegistration, isObserving else { return }
        guard !Task.isCancelled else {
            stopObserving()
            return
        }
        await refresh(workspaceId: workspaceId)
        if Task.isCancelled, registration == currentRegistration { stopObserving() }
    }

    private func subscribe(workspaceId: String, registration currentRegistration: Int) async {
        do {
            let result = try await connectionManager.request("events.subscribe", params: [
                "workspaceId": workspaceId,
                "eventTypes": ["changes:tracked", "changes:git-status", "git:*", "gitRoot:*"],
                "replaceGroup": replaceGroup
            ])
            guard let dictionary = result as? [String: Any],
                  let remoteId = dictionary["subscriptionId"] as? String, !remoteId.isEmpty else {
                throw WorkspaceChangesDecodingError.invalidChanges
            }
            guard registration == currentRegistration, isObserving, !Task.isCancelled else {
                Self.release(remoteId, via: connectionManager)
                return
            }
            subscriptionId = remoteId
        } catch {
            // Keep the one-shot snapshot and pull-to-refresh usable when subscription setup fails.
            if registration == currentRegistration, !Task.isCancelled {
                AppLog.workspace.error("[WorkspaceChangesStore] events.subscribe failed: \(error)")
            }
        }
    }

    private func handleEvent(_ params: Any) {
        guard isObserving, let workspaceId,
              let envelope = params as? [String: Any] else { return }
        let event = envelope["event"] as? [String: Any] ?? envelope
        let data = event["data"] as? [String: Any] ?? [:]
        guard let type = event["type"] as? String,
              type == "changes:tracked" || type == "changes:git-status"
              || type.hasPrefix("git:") || type.hasPrefix("gitRoot:"),
              (data["workspaceId"] as? String ?? event["workspaceId"] as? String) == workspaceId else { return }
        if let subscriptionId, let receivedId = envelope["subscriptionId"] as? String,
           receivedId != subscriptionId { return }
        // Rootless events invalidate the workspace; inventory events may change the selection.
        if !type.hasPrefix("gitRoot:"),
           let rootId = data["gitRootId"] as? String, rootId != selectedRootId { return }
        queueRefresh(workspaceId: workspaceId)
    }

    private func queueRefresh(workspaceId: String) {
        revision &+= 1
        isLoadingMore = false
        refreshQueued = true
        guard eventRefreshTask == nil else { return }
        let currentRegistration = registration
        eventRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while registration == currentRegistration, refreshQueued, !Task.isCancelled {
                refreshQueued = false
                await refresh(workspaceId: workspaceId)
            }
            if registration == currentRegistration { eventRefreshTask = nil }
        }
    }

    private static func release(_ subscriptionId: String, via connectionManager: ConnectionManagerRouting) {
        Task { @MainActor in
            do {
                _ = try await connectionManager.request("events.unsubscribe", params: ["subscriptionId": subscriptionId])
            } catch {
                AppLog.workspace.error("[WorkspaceChangesStore] events.unsubscribe failed: \(error)")
            }
        }
    }
}

extension WorkspaceChangesStore {
    private func refreshRoots(workspaceId: String, requestRevision: Int) async {
        do {
            let result = try await connectionManager.request("gitRoot.list", params: ["workspaceId": workspaceId])
            guard owns(requestRevision), !Task.isCancelled else { return }
            roots = try WorkspaceGitRoot.parseList(result)
            repositoryErrorMessage = nil
            if selectedRootId != nil, selectedRoot == nil {
                selectedRootId = nil
                clearRows()
                isLoading = true
            }
        } catch {
            guard owns(requestRevision), !Task.isCancelled, !(error is CancellationError) else { return }
            // An inventory outage must not erase known roots or prevent the primary snapshot from loading.
            repositoryErrorMessage = "Could not load repositories: \(error.localizedDescription)"
        }
    }
}
