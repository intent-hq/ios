import Foundation
import Observation

/// Display knowledge only. No read in this store starts an RPC, and none of
/// these projections may satisfy an AgentDetailStore load.
@MainActor @Observable
final class AgentSummaryStore {
    struct ReadBoundary {
        let epoch: Int
        let revision: Int
    }

    private struct Patch {
        let value: Any
        let revision: Int
        let workspaceId: String?
    }

    private var values: [String: [String: Any]] = [:]
    private var identities: [String: String] = [:]
    @ObservationIgnored private var patches: [String: [String: Patch]] = [:]
    @ObservationIgnored private var observers: [UUID: (String) -> Void] = [:]
    private var revision = 0
    private var epoch = 0

    func beginRead() -> ReadBoundary { ReadBoundary(epoch: epoch, revision: revision) }

    func cached(agentId: String) -> [String: Any] { values[agentId] ?? [:] }

    func observe(_ onChange: @escaping (String) -> Void) -> UUID {
        let id = UUID()
        observers[id] = onChange
        return id
    }

    func removeObserver(_ id: UUID) { observers[id] = nil }

    func seed(_ rows: [[String: Any]], since boundary: ReadBoundary) {
        seed(rows, workspaceId: nil, since: boundary)
    }

    func seed(_ rows: [[String: Any]], workspaceId: String?, since boundary: ReadBoundary) {
        guard boundary.epoch == epoch else { return }
        for row in rows { seedRow(row, workspaceId: workspaceId, since: boundary) }
    }

    private func seedRow(_ row: [String: Any], workspaceId: String?, since boundary: ReadBoundary) {
        guard let id = row["id"] as? String, !id.isEmpty else { return }
        let workspace = row["workspaceId"] as? String ?? workspaceId
        if let workspaceId, workspace != workspaceId { return }
        if let known = identities[id], let workspace, known != workspace { return }
        var merged = values[id] ?? ["id": id]
        if let previous = merged["workspaceId"] as? String, let workspace, previous != workspace {
            merged = ["id": id]
        }
        for (key, value) in row where Self.keys.contains(key) { merged[key] = value }
        if let workspace { merged["workspaceId"] = workspace }
        for (key, patch) in patches[id] ?? [:]
            where patch.revision > boundary.revision
                && (patch.workspaceId == nil || workspace == nil || patch.workspaceId == workspace) {
            merged[key] = patch.value
        }
        values[id] = merged
        if let workspace, row["name"] is String { identities[id] = workspace }
        for observer in observers.values { observer(id) }
    }

    func seedStatuses(_ statuses: [String: String], since boundary: ReadBoundary) {
        seed(statuses.map { ["id": $0.key, "status": $0.value] }, since: boundary)
    }

    func seedWorkspaces(_ workspaces: [Workspace], since boundary: ReadBoundary) {
        for workspace in workspaces {
            let rows: [[String: Any]] = workspace.agentSummaryAgents.map { agent in
                var row: [String: Any] = [
                    "id": agent.id, "name": agent.name, "status": agent.status,
                    "isStreaming": agent.isStreaming, "isResponding": agent.isResponding
                ]
                row["lastActivity"] = agent.lastActivity
                if let specialist = agent.specialist { row["metadata"] = ["specialist": specialist] }
                return row
            }
            seed(rows, workspaceId: workspace.id, since: boundary)
        }
    }

    func reset() {
        epoch &+= 1
        values = [:]
        identities = [:]
        patches = [:]
    }

    func handleEvent(_ params: Any) {
        guard let envelope = params as? [String: Any] else { return }
        let event = envelope["event"] as? [String: Any] ?? envelope
        guard let type = event["type"] as? String, type.hasPrefix("agent:"),
              let data = event["data"] as? [String: Any],
              let id = data["agentId"] as? String else { return }
        let workspace = (data["workspaceId"] ?? event["workspaceId"]) as? String
        if let known = identities[id], let workspace, known != workspace { return }
        let fields = eventFields(type: type, data: data, workspace: workspace)
        guard !fields.isEmpty else { return }
        revision &+= 1
        var merged = values[id] ?? ["id": id]
        for (key, value) in fields {
            merged[key] = value
            patches[id, default: [:]][key] = Patch(value: value, revision: revision, workspaceId: workspace)
        }
        values[id] = merged
        for observer in observers.values { observer(id) }
    }

    private func eventFields(type: String, data: [String: Any], workspace: String?) -> [String: Any] {
        var fields = data.filter { Self.keys.contains($0.key) && $0.key != "id" }
        fields["workspaceId"] = workspace
        if let name = data["agentName"] as? String { fields["name"] = name }
        switch type {
        case "agent:deleted": fields["status"] = "deleted"
        case "agent:idle": fields["status"] = data["status"] ?? "idle"
        case "agent:completed": fields["status"] = "completed"
        case "agent:failed": fields["status"] = "error"
        case "agent:stream:activity":
            if fields["lastAgentResponse"] is String { fields["lastMessageRole"] = "assistant" }
        default: break
        }
        if let status = fields["status"] as? String, ["idle", "completed", "deleted", "error", "failed"].contains(status) {
            fields["isStreaming"] = false
            fields["isProcessing"] = false
            fields["isResponding"] = false
        }
        return fields
    }

    private static let keys: Set<String> = [
        "id", "workspaceId", "name", "status", "metadata", "isStreaming", "isProcessing", "isResponding",
        "isWaitingForOtherAgents", "waitingForAgentIds", "createdAt", "updatedAt", "lastActivity",
        "lastAgentResponse", "lastUserMessage", "lastMessageRole", "digest", "attentionRequestKind",
        "attentionRequestReason", "attentionRequestTimestamp"
    ]
}
