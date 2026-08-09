import Foundation
import Combine

/// Live background-hook list for one workspace (PROTOCOL §5.40, §6.5).
///
/// Hooks are agent-authored (scheduling is MCP-only); this store reads via
/// `hook.list`, triggers via `hook.runNow`, cancels via `hook.cancel`, and
/// stays live by folding the `hook:*` event family into the list. The
/// `hook:*` family is not part of the bare-`*` category expansion, so the
/// store owns its own `events.subscribe` with a `hook:*` prefix filter.
@MainActor
class BackgroundHookStore: ObservableObject {
    @Published var hooks: [BackgroundHook] = []
    @Published var isLoading = false

    private var workspaceId: String?
    private var agentId: String?
    private var subscriptionId: String?
    private var eventHandlerId: UUID?
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

        connectionManager.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state == .connected {
                    Task { await self?.onConnected() }
                }
            }
            .store(in: &cancellables)
    }

    private func onConnected() async {
        // Subscriptions are per-connection (§6.1) — replay and re-seed
        subscriptionId = nil
        if let wsId = workspaceId, let agentId = agentId {
            await subscribe(workspaceId: wsId, agentId: agentId)
        }
    }

    // MARK: - Public API

    /// Registers a `hook:*` `events.subscribe` scoped to the workspace, then
    /// seeds via `hook.list` (seed after the ack so no event falls between
    /// the snapshot and the subscription window). The replace group is keyed
    /// per conversation (workspace + agent) so two simultaneously mounted
    /// same-workspace conversations don't supersede each other's subscription.
    func subscribe(workspaceId: String, agentId: String) async {
        self.workspaceId = workspaceId
        self.agentId = agentId

        if eventHandlerId == nil {
            eventHandlerId = connectionManager.onEvent { [weak self] method, params in
                Task { @MainActor in
                    self?.handleEvent(method, params: params)
                }
            }
        }

        do {
            let result = try await connectionManager.request("events.subscribe", params: [
                "eventTypes": ["hook:*"],
                "workspaceId": workspaceId,
                "replaceGroup": "ios-hooks-\(workspaceId)-\(agentId)"
            ])
            if let dict = result as? [String: Any],
               let subId = dict["subscriptionId"] as? String {
                subscriptionId = subId
            }
        } catch {
            print("[BackgroundHookStore] events.subscribe (hook:*) failed: \(error)")
        }
        // Without a subscription still serve the one-shot snapshot
        await refetch()
    }

    func unsubscribe() async {
        if let handlerId = eventHandlerId {
            connectionManager.removeEventHandler(id: handlerId)
            eventHandlerId = nil
        }
        if let subId = subscriptionId {
            subscriptionId = nil
            do {
                let _ = try await connectionManager.request("events.unsubscribe", params: [
                    "subscriptionId": subId
                ])
            } catch {
                print("[BackgroundHookStore] events.unsubscribe failed: \(error)")
            }
        }
        workspaceId = nil
        agentId = nil
        generation += 1
        hooks = []
    }

    /// `hook.runNow` (§5.40) — ack only; the run's outcome arrives as
    /// `hook:*` events.
    func runNow(hookId: String) async {
        guard let wsId = workspaceId else { return }
        do {
            let _ = try await connectionManager.request("hook.runNow", params: [
                "workspaceId": wsId,
                "hookId": hookId
            ])
        } catch {
            print("[BackgroundHookStore] hook.runNow failed: \(error)")
        }
    }

    /// `hook.cancel` (§5.40) — the `hook:cancelled` event drops the hook.
    func cancel(hookId: String) async {
        guard let wsId = workspaceId else { return }
        do {
            let _ = try await connectionManager.request("hook.cancel", params: [
                "workspaceId": wsId,
                "hookId": hookId
            ])
        } catch {
            print("[BackgroundHookStore] hook.cancel failed: \(error)")
        }
    }

    // MARK: - Event folding

    /// Event types that end a hook's life — they drop from the list.
    private static let terminalHookEvents: Set<String> = [
        "hook:dispatched", "hook:evicted", "hook:cancelled", "hook:expired"
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

    func handleEvent(_ method: String, params: Any) {
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
            print("[BackgroundHookStore] hook.list failed: \(error)")
        }
        isLoading = false
        refetchInFlight = false
        if refetchQueued {
            refetchQueued = false
            await refetch()
        }
    }
}
