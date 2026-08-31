import Foundation
import Combine
import Observation

/// Workspace-keyed PR-monitor pool for list-row rendering (PROTOCOL §5.42,
/// §6.5) — the sibling of the conversation-scoped `MonitoredPrStore` with no
/// agent filter. One global `prMonitor:*` `events.subscribe` (no
/// `workspaceId`, §6.1) covers every workspace; rows seed their workspace via
/// `prMonitor.list` on first appearance, and events fold into the seeded
/// buckets through the shared `MonitoredPrStore.foldMonitorEvent`.
@MainActor
@Observable class WorkspacePrMonitorsStore {
    static let shared = WorkspacePrMonitorsStore()

    /// Active + completed monitors per workspace, in seed order — the same
    /// pool the FE card pill/"+N" reads (cancelled rows are excluded from
    /// `prMonitor.list` and dropped by the fold).
    private(set) var monitorsByWorkspace: [String: [MonitoredPr]] = [:]

    @ObservationIgnored private var seededWorkspaceIds: Set<String> = []
    @ObservationIgnored private var subscriptionId: String?
    @ObservationIgnored private var subscribeInFlight = false
    @ObservationIgnored private var eventHandlerId: UUID?
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private let connectionManager: ConnectionManagerRouting

    // Per-workspace single-flight refetch guards
    @ObservationIgnored private var refetchInFlight: Set<String> = []
    @ObservationIgnored private var refetchQueued: Set<String> = []
    /// Bumped per workspace whenever its bucket changes outside `refetch()`,
    /// so a stale `prMonitor.list` response is discarded (same convergence
    /// scheme as `MonitoredPrStore`).
    @ObservationIgnored private var generation: [String: Int] = [:]

    init(connectionManager: ConnectionManagerRouting = ConnectionManager.shared) {
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
        guard let handlerId = eventHandlerId else { return }
        connectionManager.removeEventHandler(id: handlerId)
    }

    /// Monitors for one workspace (`[]` until seeded).
    func monitors(for workspaceId: String) -> [MonitoredPr] {
        monitorsByWorkspace[workspaceId] ?? []
    }

    /// Row-appearance entry point: ensures the global subscription exists and
    /// seeds the workspace's bucket on first sight. Later appearances are
    /// no-ops — the event fold keeps seeded buckets live.
    func seed(workspaceId: String) async {
        let firstSeed = seededWorkspaceIds.insert(workspaceId).inserted
        await ensureSubscribed()
        if firstSeed {
            await refetch(workspaceId: workspaceId)
        }
    }

    /// Subscriptions are per-connection (§6.1) — replay and re-seed every
    /// workspace already on screen.
    private func onConnected() async {
        subscriptionId = nil
        guard !seededWorkspaceIds.isEmpty else { return }
        await ensureSubscribed()
        for workspaceId in seededWorkspaceIds {
            await refetch(workspaceId: workspaceId)
        }
    }

    private func ensureSubscribed() async {
        if eventHandlerId == nil {
            eventHandlerId = connectionManager.onEvent { [weak self] method, params in
                Task { @MainActor in
                    self?.handleEvent(method, params: params)
                }
            }
        }
        guard subscriptionId == nil, !subscribeInFlight else { return }
        subscribeInFlight = true
        defer { subscribeInFlight = false }
        do {
            let result = try await connectionManager.request("events.subscribe", params: [
                "eventTypes": ["prMonitor:*"],
                "replaceGroup": "ios-pr-monitors-rows"
            ])
            if let dict = result as? [String: Any],
               let subId = dict["subscriptionId"] as? String {
                subscriptionId = subId
            }
        } catch {
            AppLog.prs.error("[WorkspacePrMonitorsStore] events.subscribe (prMonitor:*) failed: \(error)")
        }
    }

    // MARK: - Event handling

    func handleEvent(_ method: String, params: Any) {
        guard let dict = params as? [String: Any] else { return }

        let event: [String: Any]
        if let innerEvent = dict["event"] as? [String: Any] {
            event = innerEvent
        } else {
            event = dict
        }

        guard let eventType = event["type"] as? String,
              eventType.hasPrefix("prMonitor:") else { return }

        let data = event["data"] as? [String: Any] ?? [:]

        // Route to the event's workspace bucket (data-level first, envelope
        // fallback); unseeded workspaces converge via seed-on-appearance.
        guard let workspaceId = (data["workspaceId"] as? String)
            ?? (event["workspaceId"] as? String),
              seededWorkspaceIds.contains(workspaceId) else { return }

        // Match on our subscription id once known; before the ack lands,
        // accept any monitor event (the folds are idempotent).
        if let subId = subscriptionId,
           let envelopeSubId = dict["subscriptionId"] as? String,
           envelopeSubId != subId {
            return
        }

        let result = MonitoredPrStore.foldMonitorEvent(
            monitors: monitors(for: workspaceId), eventType: eventType, data: data)
        generation[workspaceId, default: 0] += 1
        monitorsByWorkspace[workspaceId] = result.monitors
        if result.needsRefetch {
            Task { await refetch(workspaceId: workspaceId) }
        }
    }

    // MARK: - Fetch

    /// Single-flight per-workspace `prMonitor.list`: concurrent requests for
    /// one workspace coalesce into a queued follow-up, and a response is
    /// applied only if the bucket's generation is unchanged since the request
    /// started (else it is stale — discard and queue one follow-up).
    func refetch(workspaceId: String) async {
        if refetchInFlight.contains(workspaceId) {
            refetchQueued.insert(workspaceId)
            return
        }
        refetchInFlight.insert(workspaceId)
        let startGeneration = generation[workspaceId, default: 0]
        do {
            let result = try await connectionManager.request("prMonitor.list", params: [
                "workspaceId": workspaceId
            ])
            if generation[workspaceId, default: 0] != startGeneration {
                refetchQueued.insert(workspaceId)
            } else if let dict = result as? [String: Any],
                      let monitorsArray = dict["monitors"] as? [[String: Any]] {
                monitorsByWorkspace[workspaceId] = monitorsArray.compactMap {
                    MonitoredPr.parseMonitor($0)
                }
            }
        } catch {
            AppLog.prs.error("[WorkspacePrMonitorsStore] prMonitor.list failed: \(error)")
        }
        refetchInFlight.remove(workspaceId)
        if refetchQueued.remove(workspaceId) != nil {
            await refetch(workspaceId: workspaceId)
        }
    }
}
