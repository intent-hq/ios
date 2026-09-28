import Foundation
import Observation

/// One session PR feed serves row and conversation leases. A row never creates
/// its own registration; each interested workspace has one acknowledged seed.
@MainActor
@Observable final class WorkspacePrMonitorsStore {
    static let shared = WorkspacePrMonitorsStore()
    let cache: WorkspaceStatusStore<MonitoredPr>

    init(connectionManager: any ConnectionManagerRouting = ConnectionManager.shared) {
        cache = WorkspaceStatusStore(
            connection: connectionManager,
            family: "prMonitor",
            listKey: "monitors",
            globalFeed: true,
            replaceGroup: "ios-pr-monitors-rows",
            eventIDKey: "monitorId",
            removalEvents: ["prMonitor:cancelled"],
            parse: MonitoredPr.parseMonitor
        ) { rows, type, data in
            let result = MonitoredPrStore.foldMonitorEvent(monitors: rows, eventType: type, data: data)
            return (result.monitors, result.needsRefetch)
        }
    }

    func monitors(for workspaceId: String) -> [MonitoredPr] { cache.buckets[workspaceId]?.rows ?? [] }
    func error(for workspaceId: String) -> String? { cache.buckets[workspaceId]?.error }

    @discardableResult
    func retain(workspaceId: String, consumer: UUID = UUID()) -> UUID {
        cache.retain(workspaceId: workspaceId, consumer: consumer)
    }

    @discardableResult
    func release(workspaceId: String, consumer: UUID) -> Task<Void, Never>? {
        cache.release(workspaceId: workspaceId, consumer: consumer)
    }

    func seed(workspaceId: String) async { await cache.load(workspaceId: workspaceId) }
    func refetch(workspaceId: String) async { await cache.load(workspaceId: workspaceId, refresh: true) }
    func handleEvent(_: String, params: Any) { cache.handleEvent(params) }
    func reset() { cache.reset() }
}
