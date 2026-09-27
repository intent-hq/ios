import Combine
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

/// Live PR-monitor list for one workspace (PROTOCOL §5.42, §6.5).
///
/// Monitors are agent-owned (registration is MCP-only); this store reads via
/// `prMonitor.list`, flushes via `prMonitor.flush`, cancels via
/// `prMonitor.cancel`, and stays live by folding the `prMonitor:*` event
/// family into the list. The `prMonitor:*` family is not part of the bare-`*`
/// category expansion, so the store owns its own `events.subscribe` with a
/// `prMonitor:*` prefix filter.
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

    var monitors: [MonitoredPr] = []
    var isLoading = false

    private var workspaceId: String?
    private var agentId: String?
    @ObservationIgnored private var subscriptionId: String?
    @ObservationIgnored private var eventHandlerId: UUID?
    @ObservationIgnored private var registrationGeneration = 0
    @ObservationIgnored private var subscriptionActive = false
    private var cancellables = Set<AnyCancellable>()
    private let connectionManager: ConnectionManagerRouting

    // Single-flight refetch guard
    private var refetchInFlight = false
    private var refetchQueued = false

    /// Bumped whenever `monitors` changes outside `refetch()` (event folds,
    /// `unsubscribe()`), so a `prMonitor.list` response that started before
    /// the change is detected as stale and discarded instead of clobbering
    /// the newer state.
    private var generation = 0

    /// Monitors in the `active` state, for display.
    var activeMonitors: [MonitoredPr] {
        monitors.filter { $0.isActive }
    }

    init(connectionManager: ConnectionManagerRouting = ConnectionManager.shared) {
        self.connectionManager = connectionManager

        var previousState = connectionManager.connectionState
        connectionManager.connectionStatePublisher
            .sink { [weak self] state in
                guard previousState != state else { return }
                previousState = state
                if state == .connected {
                    Task { await self?.onConnected() }
                }
            }
            .store(in: &cancellables)
    }

    isolated deinit {
        // Local handler removal is synchronous; the remote unsubscribe remains async.
        guard eventHandlerId != nil || subscriptionId != nil else { return }
        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
        }
        if let subscriptionId {
            Self.release(subscriptionId, via: connectionManager)
        }
    }

    private func onConnected() async {
        // Subscriptions are per-connection (§6.1) — replay and re-seed
        guard subscriptionActive, let wsId = workspaceId, let agentId else { return }
        subscriptionId = nil
        await subscribe(workspaceId: wsId, agentId: agentId)
    }

    // MARK: - Public API

    /// Registers a `prMonitor:*` `events.subscribe` scoped to the workspace,
    /// then seeds via `prMonitor.list` (seed after the ack so no event falls
    /// between the snapshot and the subscription window). The replace group
    /// is keyed per conversation (workspace + agent) so two simultaneously
    /// mounted same-workspace conversations don't supersede each other's
    /// subscription.
    func subscribe(workspaceId: String, agentId: String) async {
        guard !Task.isCancelled else { return }
        registrationGeneration &+= 1
        let registration = registrationGeneration
        subscriptionActive = true
        self.workspaceId = workspaceId
        self.agentId = agentId

        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
        }
        let previousSubscriptionId = subscriptionId
        subscriptionId = nil
        if let previousSubscriptionId {
            await release(previousSubscriptionId)
        }
        guard owns(registration), !Task.isCancelled else { return }

        eventHandlerId = connectionManager.onEvent { [weak self] method, params in
            Task { @MainActor [weak self] in
                guard let self, owns(registration) else { return }
                handleEvent(method, params: params)
            }
        }

        let outcome: Result<String?, Error>
        do {
            let result = try await connectionManager.request("events.subscribe", params: [
                "eventTypes": ["prMonitor:*"],
                "workspaceId": workspaceId,
                "replaceGroup": "ios-pr-monitors-\(workspaceId)-\(agentId)"
            ])
            outcome = .success((result as? [String: Any])?["subscriptionId"] as? String)
        } catch {
            outcome = .failure(error)
        }
        guard owns(registration), !Task.isCancelled else {
            if case .success(let orphanedId?) = outcome {
                Self.release(orphanedId, via: connectionManager)
            }
            return
        }
        switch outcome {
        case .success(let subscriptionId):
            self.subscriptionId = subscriptionId
        case .failure(let error):
            AppLog.prs.error("[MonitoredPrStore] events.subscribe (prMonitor:*) failed: \(error)")
        }
        // Without a subscription still serve the one-shot snapshot
        await refetch()
    }

    func unsubscribe() async {
        if let subscriptionId = detachSubscription() {
            await release(subscriptionId)
        }
    }

    /// Synchronously invalidates ownership for a disappearing screen, then
    /// releases the captured remote id without retaining mutable store state.
    func deactivate() {
        if let subscriptionId = detachSubscription() {
            Self.release(subscriptionId, via: connectionManager)
        }
    }

    private func detachSubscription() -> String? {
        registrationGeneration &+= 1
        subscriptionActive = false
        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
            eventHandlerId = nil
        }
        let detachedSubscriptionId = subscriptionId
        subscriptionId = nil
        workspaceId = nil
        agentId = nil
        generation += 1
        monitors = []
        return detachedSubscriptionId
    }

    private func owns(_ registration: Int) -> Bool {
        subscriptionActive && registration == registrationGeneration
    }

    private func release(_ subscriptionId: String) async {
        do {
            _ = try await connectionManager.request("events.unsubscribe", params: [
                "subscriptionId": subscriptionId
            ])
        } catch {
            AppLog.prs.error("[MonitoredPrStore] events.unsubscribe failed: \(error)")
        }
    }

    private static func release(_ subscriptionId: String, via connectionManager: ConnectionManagerRouting) {
        Task { @MainActor in
            do {
                _ = try await connectionManager.request("events.unsubscribe", params: [
                    "subscriptionId": subscriptionId
                ])
            } catch {
                AppLog.prs.error("[MonitoredPrStore] events.unsubscribe failed: \(error)")
            }
        }
    }

    /// `prMonitor.flush` (§5.42) — delivers a monitor's pending consolidated
    /// wake now; ack only, the outcome arrives as `prMonitor:*` events.
    /// `check: true` makes the daemon re-poll the PR first and flush anything
    /// that changed vs. the emit baseline (additive param, default `false`);
    /// daemonDefault omits the key so older daemons see the pre-check request.
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

    /// `prMonitor.cancel` (§5.42) — the `prMonitor:cancelled` event drops
    /// the monitor.
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
        /// The event referenced a monitor this list has never seen — the
        /// fold cannot invent the missing wire fields (`createdAt`,
        /// `lastSnapshot`, …) since `prMonitor:*` payloads carry only
        /// `{ workspaceId, agentId, monitorId, repo, prNumber, state }`
        /// (plus `changes` on `prMonitor:changed`), so the caller should
        /// re-run `prMonitor.list` to converge.
        let needsRefetch: Bool
    }

    /// Pure fold of one `prMonitor:*` event into the current monitor list.
    static func foldMonitorEvent(
        monitors: [MonitoredPr],
        eventType: String,
        data: [String: Any]
    ) -> FoldResult {
        guard let monitorId = data["monitorId"] as? String,
              let eventKind = MonitorEventKind(eventType: eventType) else {
            return FoldResult(monitors: monitors, needsRefetch: false)
        }

        // Cancelled rows are excluded from `prMonitor.list` — drop them.
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
            // Fires on registration and on an idempotent re-arm; a re-arm
            // refreshes the monitor's baseline server-side, so clear the
            // pre-re-arm pending state immediately and refetch to converge
            // on the refreshed row (fresh `lastSnapshot`, timestamps, …).
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
            // The consolidated wake was delivered — pending changes cleared.
            next[index].state = payloadState ?? next[index].state
            next[index].pendingChanges = []
            next[index].hasPendingChanges = false
            next[index].pendingSince = nil
        case .completed:
            // PR merged/closed — the row is retained (completed monitors
            // stay visible) with the immediate final wake delivered.
            next[index].state = payloadState ?? .completed
            next[index].pendingChanges = []
            next[index].hasPendingChanges = false
            next[index].pendingSince = nil
        case .cancelled:
            return FoldResult(monitors: monitors, needsRefetch: false)
        }
        return FoldResult(monitors: next, needsRefetch: false)
    }

    // MARK: - Event handling

    func handleEvent(_: String, params: Any) {
        guard subscriptionActive else { return }
        guard let dict = params as? [String: Any] else { return }

        // Events from the event bridge are wrapped:
        // { subscriptionId, event: { type, workspaceId, timestamp, data } }
        let event: [String: Any]
        if let innerEvent = dict["event"] as? [String: Any] {
            event = innerEvent
        } else {
            event = dict
        }

        guard let eventType = event["type"] as? String,
              eventType.hasPrefix("prMonitor:") else { return }

        let data = event["data"] as? [String: Any] ?? [:]

        // Scope to this workspace (data-level first, envelope fallback)
        guard let wsId = workspaceId else { return }
        let eventWorkspaceId = (data["workspaceId"] as? String)
            ?? (event["workspaceId"] as? String)
        guard eventWorkspaceId == wsId else { return }

        // Match on our subscription id once known; before the ack lands,
        // accept any monitor event for this workspace (the folds are idempotent)
        if let subId = subscriptionId,
           let envelopeSubId = dict["subscriptionId"] as? String,
           envelopeSubId != subId {
            return
        }

        let result = Self.foldMonitorEvent(monitors: monitors, eventType: eventType, data: data)
        generation += 1
        monitors = result.monitors
        if result.needsRefetch {
            Task { await refetch() }
        }
    }

    // MARK: - Fetch

    /// Single-flight `prMonitor.list` refetch: concurrent requests coalesce
    /// into one queued follow-up so event storms cannot stack fetches. A
    /// response is applied only if `generation` is unchanged since the
    /// request started — an event fold or `unsubscribe()` that landed while
    /// the request was suspended makes the response stale, so it is
    /// discarded and one follow-up fetch is queued to converge.
    func refetch() async {
        guard let wsId = workspaceId else { return }
        if refetchInFlight {
            refetchQueued = true
            return
        }
        refetchInFlight = true
        isLoading = true
        let startGeneration = generation
        do {
            let result = try await connectionManager.request("prMonitor.list", params: [
                "workspaceId": wsId
            ])
            if generation != startGeneration {
                refetchQueued = true
            } else if let dict = result as? [String: Any],
                      let monitorsArray = dict["monitors"] as? [[String: Any]] {
                monitors = monitorsArray.compactMap { MonitoredPr.parseMonitor($0) }
            }
        } catch {
            AppLog.prs.error("[MonitoredPrStore] prMonitor.list failed: \(error)")
        }
        isLoading = false
        refetchInFlight = false
        if refetchQueued {
            refetchQueued = false
            await refetch()
        }
    }
}
