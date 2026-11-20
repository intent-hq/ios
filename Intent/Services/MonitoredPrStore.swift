import Foundation
import Observation

enum PrMonitorFlushMode {
    case daemonDefault
    case pendingOnly
    case refreshFirst

    func apply(to params: inout [String: Any]) {
        switch self {
        case .daemonDefault:
            break
        case .pendingOnly:
            params["check"] = false
        case .refreshFirst:
            params["check"] = true
        }
    }
}

@MainActor
@Observable class MonitoredPrStore {
    private enum MonitorEventKind {
        case cancelled
        case changed
        case completed
        case emitted
        case registered

        init?(eventType: String) {
            switch eventType {
            case "prMonitor:cancelled": self = .cancelled
            case "prMonitor:changed": self = .changed
            case "prMonitor:completed": self = .completed
            case "prMonitor:emitted": self = .emitted
            case "prMonitor:registered": self = .registered
            default: return nil
            }
        }

        var needsRefetchWhenMissing: Bool {
            self != .cancelled
        }
    }

    let source: WorkspacePrMonitorsStore
    private let connectionManager: any ConnectionManagerRouting
    private var workspaceId: String?
    private var consumer: UUID?

    var monitors: [MonitoredPr] { workspaceId.map { source.monitors(for: $0) } ?? [] }
    var isLoading: Bool { workspaceId.flatMap { source.cache.buckets[$0]?.isLoading } ?? false }
    var error: String? { workspaceId.flatMap { source.cache.buckets[$0]?.error } }
    var isStale: Bool { workspaceId.flatMap { source.cache.buckets[$0]?.isStale } ?? true }
    var activeMonitors: [MonitoredPr] { monitors.filter { $0.isActive } }

    init(
        connectionManager: any ConnectionManagerRouting = ConnectionManager.shared,
        source: WorkspacePrMonitorsStore? = nil
    ) {
        self.connectionManager = connectionManager
        self.source = source ?? WorkspacePrMonitorsStore(connectionManager: connectionManager)
    }

    isolated deinit { deactivate() }

    func activate(workspaceId: String) {
        guard self.workspaceId != workspaceId || consumer == nil else { return }
        deactivate()
        self.workspaceId = workspaceId
        consumer = source.retain(workspaceId: workspaceId)
    }

    func subscribe(workspaceId: String, agentId _: String) async {
        guard !Task.isCancelled else { return }
        activate(workspaceId: workspaceId)
        let activation = consumer
        await source.seed(workspaceId: workspaceId)
        if Task.isCancelled, consumer == activation { deactivate() }
    }

    func unsubscribe() async { await detach()?.value }
    func deactivate() { _ = detach() }

    private func detach() -> Task<Void, Never>? {
        defer { workspaceId = nil; consumer = nil }
        guard let workspaceId, let consumer else { return nil }
        return source.release(workspaceId: workspaceId, consumer: consumer)
    }

    func refetch() async {
        guard let workspaceId else { return }
        await source.refetch(workspaceId: workspaceId)
    }

    func handleEvent(_: String, params: Any) { source.handleEvent("", params: params) }

    func flush(monitorId: String, mode: PrMonitorFlushMode = .daemonDefault) async {
        guard let wsId = workspaceId else { return }
        var params: [String: Any] = [
            "workspaceId": wsId,
            "monitorId": monitorId
        ]
        mode.apply(to: &params)
        do {
            _ = try await connectionManager.request("prMonitor.flush", params: params)
        } catch {
            AppLog.prs.error("[MonitoredPrStore] prMonitor.flush failed: \(error)")
        }
    }

    func cancel(monitorId: String) async {
        guard let wsId = workspaceId else { return }
        do {
            _ = try await connectionManager.request("prMonitor.cancel", params: [
                "workspaceId": wsId,
                "monitorId": monitorId
            ])
        } catch {
            AppLog.prs.error("[MonitoredPrStore] prMonitor.cancel failed: \(error)")
        }
    }

    // MARK: - Event folding

    struct FoldResult {
        let monitors: [MonitoredPr]
        let needsRefetch: Bool
    }

    static func foldMonitorEvent(
        monitors: [MonitoredPr],
        eventType: String,
        data: [String: Any]
    ) -> FoldResult {
        guard let monitorId = data["monitorId"] as? String,
              let eventKind = MonitorEventKind(eventType: eventType) else {
            return FoldResult(monitors: monitors, needsRefetch: false)
        }

        if eventKind == .cancelled {
            return FoldResult(
                monitors: monitors.filter { $0.monitorId != monitorId },
                needsRefetch: false
            )
        }

        guard let index = monitors.firstIndex(where: { $0.monitorId == monitorId }) else {
            return FoldResult(
                monitors: monitors,
                needsRefetch: eventKind.needsRefetchWhenMissing
            )
        }

        let payloadState = (data["state"] as? String).flatMap(MonitoredPr.State.init)

        var next = monitors
        switch eventKind {
        case .registered:
            next[index].state = payloadState ?? .active
            next[index].pendingChanges = []
            next[index].hasPendingChanges = false
            next[index].pendingSince = nil
            return FoldResult(monitors: next, needsRefetch: true)
        case .changed:
            next[index].state = payloadState ?? next[index].state
            if let changes = data["changes"] as? [String] {
                next[index].pendingChanges = changes
                next[index].hasPendingChanges = !changes.isEmpty
            }
        case .emitted:
            next[index].state = payloadState ?? next[index].state
            next[index].pendingChanges = []
            next[index].hasPendingChanges = false
            next[index].pendingSince = nil
        case .completed:
            next[index].state = payloadState ?? .completed
            next[index].pendingChanges = []
            next[index].hasPendingChanges = false
            next[index].pendingSince = nil
        case .cancelled:
            return FoldResult(monitors: monitors, needsRefetch: false)
        }
        return FoldResult(monitors: next, needsRefetch: false)
    }
}
