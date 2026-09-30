import Foundation
import Observation

/// A conversation's lease on the session-owned workspace hook cache.
@MainActor
@Observable class BackgroundHookStore {
    let source: WorkspaceStatusStore<BackgroundHook>
    private let connectionManager: any ConnectionManagerRouting
    private var workspaceId: String?
    private var consumer: UUID?

    var hooks: [BackgroundHook] { workspaceId.flatMap { source.buckets[$0]?.rows } ?? [] }
    var isLoading: Bool { workspaceId.flatMap { source.buckets[$0]?.isLoading } ?? false }
    var error: String? { workspaceId.flatMap { source.buckets[$0]?.error } }
    var isStale: Bool { workspaceId.flatMap { source.buckets[$0]?.isStale } ?? true }
    var activeHooks: [BackgroundHook] { hooks.filter { $0.isActive } }

    init(
        connectionManager: any ConnectionManagerRouting = ConnectionManager.shared,
        source: WorkspaceStatusStore<BackgroundHook>? = nil
    ) {
        self.connectionManager = connectionManager
        self.source = source ?? Self.makeWorkspaceStore(connection: connectionManager)
    }

    static func makeWorkspaceStore(connection: any ConnectionManagerRouting) -> WorkspaceStatusStore<BackgroundHook> {
        WorkspaceStatusStore(
            connection: connection,
            family: "hook",
            listKey: "hooks",
            globalFeed: false,
            replaceGroup: "ios-hooks",
            eventIDKey: "hookId",
            removalEvents: terminalHookEvents,
            parse: BackgroundHook.parseHook
        ) { rows, type, data in
            let result = foldHookEvent(hooks: rows, eventType: type, data: data)
            return (result.hooks, result.needsRefetch)
        }
    }

    isolated deinit { deactivate() }

    func subscribe(workspaceId: String, agentId _: String) async {
        guard !Task.isCancelled else { return }
        if self.workspaceId != workspaceId || consumer == nil {
            deactivate()
            self.workspaceId = workspaceId
            consumer = source.retain(workspaceId: workspaceId)
        }
        let activation = consumer
        await source.load(workspaceId: workspaceId)
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
        await source.load(workspaceId: workspaceId, refresh: true)
    }

    func handleEvent(_: String, params: Any) { source.handleEvent(params) }

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
}
