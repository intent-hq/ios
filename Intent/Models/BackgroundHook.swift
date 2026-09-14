import Foundation

/// Wire `Hook` shape (PROTOCOL §5.40, v3.1). `code` arrives on `hook.list`
/// only — `hook:*` event payloads never carry it, so event folds must copy
/// the existing hook to retain it. `lastLogs`/`lastState` are deliberately
/// not modeled (display does not need them; clients read via `hook.list`).
struct BackgroundHook: Identifiable, Equatable {
    /// Hook lifecycle state (PROTOCOL §5.40).
    /// `scheduled`/`running` are the active states; `dispatched`/`evicted`/
    /// `cancelled`/`expired` are terminal.
    enum State: String {
        case scheduled
        case running
        case dispatched
        case evicted
        case cancelled
        case expired
    }

    let hookId: String
    let workspaceId: String
    let agentId: String
    let name: String
    let code: String?
    let delayMs: Int
    var state: State
    let createdAt: String?
    /// TTL deadline (v3.1); absent only on pre-TTL legacy rows.
    let expiresAt: String?
    var lastRunAt: String?
    var nextRunAt: String?
    let runCount: Int
    /// Perpetual hooks re-arm after a dispatch instead of retiring (v6.0);
    /// always present on the wire from v6.0, defaulted false when absent.
    let perpetual: Bool
    var lastError: String?

    var id: String { hookId }

    /// Whether the hook is in an active state (`scheduled` or `running`).
    var isActive: Bool {
        state == .scheduled || state == .running
    }

    static func parseHook(_ dict: [String: Any]) -> Self? {
        guard let hookId = dict["hookId"] as? String,
              let name = dict["name"] as? String,
              let stateRaw = dict["state"] as? String,
              let state = State(rawValue: stateRaw) else { return nil }
        return Self(
            hookId: hookId,
            workspaceId: dict["workspaceId"] as? String ?? "",
            agentId: dict["agentId"] as? String ?? "",
            name: name,
            code: dict["code"] as? String,
            delayMs: dict["delayMs"] as? Int ?? 0,
            state: state,
            createdAt: dict["createdAt"] as? String,
            expiresAt: dict["expiresAt"] as? String,
            lastRunAt: dict["lastRunAt"] as? String,
            nextRunAt: dict["nextRunAt"] as? String,
            runCount: dict["runCount"] as? Int ?? 0,
            perpetual: dict["perpetual"] as? Bool ?? false,
            lastError: dict["lastError"] as? String
        )
    }
}
