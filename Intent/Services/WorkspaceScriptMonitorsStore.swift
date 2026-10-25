import Combine
import Foundation
import Observation

/// Session-owned active summaries. Only visible conversations retain a lease.
@MainActor
@Observable final class WorkspaceScriptMonitorsStore {
    let cache: WorkspaceStatusStore<ScriptMonitorSummary>
    let connection: any ConnectionManagerRouting
    private(set) var isSupported = false
    @ObservationIgnored private var observations: [AnyCancellable] = []
    @ObservationIgnored private var disabled = false
    @ObservationIgnored private let supportOverride: (() -> Bool)?
    var selections: [UUID: Selection] = [:]

    init(connection: any ConnectionManagerRouting, supported: (() -> Bool)? = nil) {
        self.connection = connection
        supportOverride = supported
        cache = WorkspaceStatusStore(
            connection: connection,
            family: "scriptMonitor",
            listKey: "monitors",
            globalFeed: false,
            replaceGroup: "ios-script-monitors",
            eventIDKey: "monitorId",
            removalEvents: Self.terminalEvents,
            parse: { _ in nil },
            fold: Self.fold
        )
        cache.pageAdapter = WorkspaceStatusPageAdapter(
            canLoad: { [weak self] in self?.isSupported == true },
            request: { workspaceId, cursor in
                var params: [String: Any] = ["workspaceId": workspaceId, "view": "summary", "state": "active", "limit": 100]
                if let cursor { params["cursor"] = cursor }
                let result = try await connection.request("scriptMonitor.list", params: params)
                let page = try ScriptMonitorPage(result, workspaceId: workspaceId)
                guard page.monitors.count <= 100 else { throw ScriptMonitorReadError.invalidResponse }
                return .init(rows: page.monitors, nextCursor: page.nextCursor)
            },
            merge: Self.merge,
            normalizeEvent: Self.normalizeEvent,
            identity: Self.identity,
            didReceive: { [weak self] type, data, workspace in self?.receiveDetailEvent(type, data: data, workspaceId: workspace) },
            didFail: { [weak self] error, workspace in self?.readFailed(error, workspaceId: workspace) },
            didReplacePage: { [weak self] workspace in self?.revalidateDetails(workspaceId: workspace) }
        )
        observations.append(connection.capabilitiesPublisher.sink { [weak self] _ in self?.supportChanged() })
        var previousState = connection.connectionState
        observations.append(connection.connectionStatePublisher.sink { [weak self] state in
            guard let self else { return }
            if previousState != state {
                previousState = state
                disabled = false
                invalidateDetails()
            }
            supportChanged()
        })
    }

    func rows(for workspaceId: String) -> [ScriptMonitorSummary] { cache.buckets[workspaceId]?.rows ?? [] }
    func isLoading(for workspaceId: String) -> Bool { cache.buckets[workspaceId]?.isLoading ?? false }
    func isStale(for workspaceId: String) -> Bool { cache.buckets[workspaceId]?.isStale ?? true }
    func error(for workspaceId: String) -> String? { cache.buckets[workspaceId]?.error }
    func nextCursor(for workspaceId: String) -> String? { cache.buckets[workspaceId]?.nextCursor }

    @discardableResult
    func retain(workspaceId: String, consumer: UUID = UUID()) -> UUID {
        cache.retain(workspaceId: workspaceId, consumer: consumer)
    }

    @discardableResult
    func release(workspaceId: String, consumer: UUID) -> Task<Void, Never>? {
        let cleanup = cache.release(workspaceId: workspaceId, consumer: consumer)
        if cache.buckets[workspaceId]?.consumers.isEmpty == true {
            for (id, selection) in selections where selection.workspaceId == workspaceId { deselect(selection: id) }
        }
        return cleanup
    }

    func load(workspaceId: String) async { await cache.load(workspaceId: workspaceId) }
    func refresh(workspaceId: String) async { await cache.load(workspaceId: workspaceId, refresh: true) }
    func loadMore(workspaceId: String) async { await cache.load(workspaceId: workspaceId, nextPage: true) }
    func retry(workspaceId: String) async {
        if cache.buckets[workspaceId]?.failedNextPage == true { await loadMore(workspaceId: workspaceId) } else { await refresh(workspaceId: workspaceId) }
    }

    func handleEvent(_: String, params: Any) { cache.handleEvent(params) }

    func reset() {
        for id in Array(selections.keys) { deselect(selection: id) }
        cache.reset()
    }

    private func supportChanged() {
        let supported = !disabled && connection.connectionState == .connected
            && (supportOverride?() ?? connection.capabilities.supportsScriptMonitors)
        guard isSupported != supported else { return }
        isSupported = supported
        if !supported {
            for feed in cache.feeds.values { cache.releaseRemote(feed) }
            cache.invalidateConnection()
            invalidateDetails()
        } else {
            for (workspace, bucket) in cache.buckets where !bucket.consumers.isEmpty {
                Task { await self.load(workspaceId: workspace) }
            }
            for id in selections.keys { Task { await self.loadDetail(selection: id) } }
        }
    }

    static let methodNotFound = -32_601
    static let invalidParameters = -32_602
    static let forbidden = -32_003

    func readFailed(_ error: Error, workspaceId: String) {
        let rpc = error as NSError
        if error as? ScriptMonitorReadError == .unsupportedView || (rpc.domain == "WebSocket" && rpc.code == Self.methodNotFound) {
            disabled = true
            connection.disableScriptMonitors()
            supportChanged()
        } else if rpc.domain == "WebSocket", rpc.code == Self.forbidden {
            clearInaccessible(workspaceId: workspaceId)
        }
    }

    private func clearInaccessible(workspaceId: String) {
        cache.denyAccess(workspaceId: workspaceId, message: "Script watches are unavailable. Retry to check access.")
        for selection in selections.values where selection.workspaceId == workspaceId {
            selection.summary = nil
            selection.invalidate(state: .failed("Script watch details are unavailable. Retry to check access."))
        }
    }
}
