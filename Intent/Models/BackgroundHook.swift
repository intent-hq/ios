import Foundation

struct BackgroundHook: Identifiable, Equatable {
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
    let expiresAt: String?
    var lastRunAt: String?
    var nextRunAt: String?
    let runCount: Int
    let perpetual: Bool
    var lastError: String?

    var id: String { hookId }

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
