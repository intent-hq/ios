import Foundation
import Observation

/// Display knowledge only. No read in this store starts an RPC, and none of
/// these projections may satisfy an AgentDetailStore load.
@MainActor @Observable
final class AgentSummaryStore {
    struct ReadBoundary {
        let epoch: Int
        let sequence: Int
    }

    private enum Field: Hashable {
        case value(String)
        case metadata(String)
    }

    private struct Patch {
        let value: Any
        let sequence: Int
        let workspaceId: String?
    }

    private var values: [String: [String: Any]] = [:]
    private var identities: [String: String] = [:]
    @ObservationIgnored private var patches: [String: [Field: Patch]] = [:]
    @ObservationIgnored private var observers: [UUID: (String) -> Void] = [:]
    private var sequence = 0
    private var epoch = 0

    /// A successful response owns only its supplied fields, in RPC start order.
    /// A late list cannot replace a newer detail or event, but may fill omissions.
    func beginRead() -> ReadBoundary {
        sequence &+= 1
        return ReadBoundary(epoch: epoch, sequence: sequence)
    }

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
        if let workspace {
            // Before a read establishes identity, events can supply provisional
            // display data. Discard fields from another workspace on resolution.
            patches[id] = patches[id]?.filter { $0.value.workspaceId == nil || $0.value.workspaceId == workspace }
        }
        var fields = displayFields(row)
        if let workspace { fields[.value("workspaceId")] = workspace }
        apply(fields, agentId: id, workspaceId: workspace, sequence: boundary.sequence)
        if let workspace, !workspace.isEmpty, let name = row["name"] as? String, !name.isEmpty { identities[id] = workspace }
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
        if let workspace, !workspace.isEmpty, let name = fields["name"] as? String, !name.isEmpty {
            identities[id] = workspace
            patches[id] = patches[id]?.filter { $0.value.workspaceId == nil || $0.value.workspaceId == workspace }
        }
        sequence &+= 1
        apply(displayFields(fields), agentId: id, workspaceId: workspace, sequence: sequence)
    }

    private func eventFields(type: String, data: [String: Any], workspace: String?) -> [String: Any] {
        var fields = data.filter { Self.keys.contains($0.key) && $0.key != "id" }
        // Mutations publish these display changes flat, unlike AgentLite metadata.
        fields["specialist"] = data["specialist"]
        fields["attentionRequestCleared"] = data["attentionRequestCleared"]
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
        return fields
    }

    private func displayFields(_ row: [String: Any]) -> [Field: Any] {
        var fields: [Field: Any] = [:]
        for (key, value) in row where Self.keys.contains(key) && key != "metadata" && key != "id" {
            fields[.value(key)] = value
        }
        let metadata = row["metadata"] as? [String: Any] ?? [:]
        for (key, value) in metadata { fields[.metadata(key)] = value }
        if let specialist = row["specialist"] { fields[.metadata("specialist")] = specialist }
        // Both wire surfaces describe the same attention fields. Mirroring them
        // avoids a stale top-level value masking a newer metadata value (or clear).
        for key in Self.attentionKeys {
            let value: Any? = row["attentionRequestCleared"] as? Bool == true ? NSNull() : row[key] ?? metadata[key]
            if let value {
                fields[.value(key)] = value
                fields[.metadata(key)] = value
            }
        }
        if let status = row["status"] as? String, Self.inactiveStatuses.contains(status.lowercased()) {
            // Status-only subscriptions must retire older liveness. Explicit
            // live overlays and newer events retain their own field provenance.
            for key in ["isStreaming", "isProcessing", "isResponding"] where row[key] == nil {
                fields[.value(key)] = false
            }
        }
        return fields
    }

    private func apply(_ fields: [Field: Any], agentId: String, workspaceId: String?, sequence: Int) {
        for (field, value) in fields where (patches[agentId]?[field]?.sequence ?? 0) <= sequence {
            patches[agentId, default: [:]][field] = Patch(value: value, sequence: sequence, workspaceId: workspaceId)
        }
        var merged: [String: Any] = ["id": agentId]
        var metadata: [String: Any] = [:]
        for (field, patch) in patches[agentId] ?? [:] {
            switch field {
            case .value(let key): merged[key] = patch.value
            case .metadata(let key): metadata[key] = patch.value
            }
        }
        if !metadata.isEmpty { merged["metadata"] = metadata }
        values[agentId] = merged
        for observer in observers.values { observer(agentId) }
    }

    private static let inactiveStatuses: Set<String> = ["idle", "completed", "deleted", "error", "failed"]
    private static let attentionKeys = ["attentionRequestKind", "attentionRequestReason", "attentionRequestTimestamp"]

    private static let keys: Set<String> = [
        "id", "workspaceId", "name", "status", "metadata", "isStreaming", "isProcessing", "isResponding",
        "isWaitingForOtherAgents", "waitingForAgentIds", "createdAt", "updatedAt", "lastActivity",
        "lastAgentResponse", "lastUserMessage", "lastMessageRole", "digest", "attentionRequestKind",
        "attentionRequestReason", "attentionRequestTimestamp"
    ]
}
