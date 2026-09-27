import Combine
import Foundation
import Observation

/// Live background-hook list for one workspace (PROTOCOL §5.40, §6.5).
///
/// Hooks are agent-authored (scheduling is MCP-only); this store reads via
/// `hook.list`, triggers via `hook.runNow`, cancels via `hook.cancel`, and
/// stays live by folding the `hook:*` event family into the list. The
/// `hook:*` family is not part of the bare-`*` category expansion, so the
/// store owns its own `events.subscribe` with a `hook:*` prefix filter.
@MainActor
@Observable class BackgroundHookStore {
    var hooks: [BackgroundHook] = []
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

    /// Bumped whenever `hooks` changes outside `refetch()` (event folds,
    /// `unsubscribe()`), so a `hook.list` response that started before the
    /// change is detected as stale and discarded instead of clobbering the
    /// newer state.
    private var generation = 0

    /// Hooks in an active state (`scheduled`/`running`), for display.
    var activeHooks: [BackgroundHook] {
        hooks.filter { $0.isActive }
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

    /// Registers a `hook:*` `events.subscribe` scoped to the workspace, then
    /// seeds via `hook.list` (seed after the ack so no event falls between
    /// the snapshot and the subscription window). The replace group is keyed
    /// per conversation (workspace + agent) so two simultaneously mounted
    /// same-workspace conversations don't supersede each other's subscription.
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
                "eventTypes": ["hook:*"],
                "workspaceId": workspaceId,
                "replaceGroup": "ios-hooks-\(workspaceId)-\(agentId)"
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
            AppLog.hooks.error("[BackgroundHookStore] events.subscribe (hook:*) failed: \(error)")
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
        hooks = []
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
            AppLog.hooks.error("[BackgroundHookStore] events.unsubscribe failed: \(error)")
        }
    }

    private static func release(_ subscriptionId: String, via connectionManager: ConnectionManagerRouting) {
        Task { @MainActor in
            do {
                _ = try await connectionManager.request("events.unsubscribe", params: [
                    "subscriptionId": subscriptionId
                ])
            } catch {
                AppLog.hooks.error("[BackgroundHookStore] events.unsubscribe failed: \(error)")
            }
        }
    }

    /// `hook.runNow` (§5.40) — ack only; the run's outcome arrives as
    /// `hook:*` events.
    func runNow(hookId: String) async {
        guard let wsId = workspaceId else { return }
        do {
            _ = try await connectionManager.request("hook.runNow", params: [
                "workspaceId": wsId,
                "hookId": hookId
            ])
        } catch {
            AppLog.hooks.error("[BackgroundHookStore] hook.runNow failed: \(error)")
        }
    }

    /// `hook.cancel` (§5.40) — the `hook:cancelled` event drops the hook.
    func cancel(hookId: String) async {
        guard let wsId = workspaceId else { return }
        do {
            _ = try await connectionManager.request("hook.cancel", params: [
                "workspaceId": wsId,
                "hookId": hookId
            ])
        } catch {
            AppLog.hooks.error("[BackgroundHookStore] hook.cancel failed: \(error)")
        }
    }

    // MARK: - Event folding

    /// Event types that end a hook's life — they drop from the list.
    private static let terminalHookEvents: Set<String> = [
        "hook:dispatched",
        "hook:evicted",
        "hook:cancelled",
        "hook:expired"
    ]

    struct FoldResult {
        let hooks: [BackgroundHook]
        /// The event referenced a hook this list has never seen — the fold
        /// cannot invent the missing wire fields (`delayMs`, `createdAt`),
        /// so the caller should re-run `hook.list` to converge.
        let needsRefetch: Bool
    }

    /// Pure fold of one `hook:*` event into the current hook list
    /// (mirrors the cloudlands-fe `foldHookEvent`).
    static func foldHookEvent(
        hooks: [BackgroundHook],
        eventType: String,
        data: [String: Any]
    ) -> FoldResult {
        guard let hookId = data["hookId"] as? String else {
            return FoldResult(hooks: hooks, needsRefetch: false)
        }

        if terminalHookEvents.contains(eventType) {
            return FoldResult(
                hooks: hooks.filter { $0.hookId != hookId },
                needsRefetch: false
            )
        }

        guard let index = hooks.firstIndex(where: { $0.hookId == hookId }) else {
            switch eventType {
            case "hook:scheduled", "hook:run-started", "hook:run-completed":
                return FoldResult(hooks: hooks, needsRefetch: true)
            default:
                return FoldResult(hooks: hooks, needsRefetch: false)
            }
        }

        var next = hooks
        switch eventType {
        case "hook:scheduled":
            next[index].state = .scheduled
            next[index].nextRunAt = data["nextRunAt"] as? String ?? next[index].nextRunAt
        case "hook:run-started":
            next[index].state = .running
        case "hook:run-completed":
            // `nextRunAt` present ⇒ the hook stays scheduled; absent ⇒ a
            // terminal dispatched/evicted event follows and drops it (§6.5).
            next[index].state = .scheduled
            next[index].nextRunAt = data["nextRunAt"] as? String
        default:
            return FoldResult(hooks: hooks, needsRefetch: false)
        }
        return FoldResult(hooks: next, needsRefetch: false)
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
              eventType.hasPrefix("hook:") else { return }

        let data = event["data"] as? [String: Any] ?? [:]

        // Scope to this workspace (data-level first, envelope fallback)
        guard let wsId = workspaceId else { return }
        let eventWorkspaceId = (data["workspaceId"] as? String)
            ?? (event["workspaceId"] as? String)
        guard eventWorkspaceId == wsId else { return }

        // Match on our subscription id once known; before the ack lands,
        // accept any hook event for this workspace (the folds are idempotent)
        if let subId = subscriptionId,
           let envelopeSubId = dict["subscriptionId"] as? String,
           envelopeSubId != subId {
            return
        }

        let result = Self.foldHookEvent(hooks: hooks, eventType: eventType, data: data)
        generation += 1
        hooks = result.hooks
        if result.needsRefetch {
            Task { await refetch() }
        }
    }

    // MARK: - Fetch

    /// Single-flight `hook.list` refetch: concurrent requests coalesce into
    /// one queued follow-up so event storms cannot stack fetches. A response
    /// is applied only if `generation` is unchanged since the request
    /// started — an event fold or `unsubscribe()` that landed while the
    /// request was suspended makes the response stale, so it is discarded
    /// and one follow-up fetch is queued to converge.
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
            let result = try await connectionManager.request("hook.list", params: [
                "workspaceId": wsId
            ])
            if generation != startGeneration {
                refetchQueued = true
            } else if let dict = result as? [String: Any],
                      let hooksArray = dict["hooks"] as? [[String: Any]] {
                hooks = hooksArray.compactMap { BackgroundHook.parseHook($0) }
            }
        } catch {
            AppLog.hooks.error("[BackgroundHookStore] hook.list failed: \(error)")
        }
        isLoading = false
        refetchInFlight = false
        if refetchQueued {
            refetchQueued = false
            await refetch()
        }
    }
}
