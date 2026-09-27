import Combine
import Foundation
import Observation

/// Only an agent.get response creates detail knowledge. Summary/list rows must
/// not seed this store: they omit fields such as pending proposal receipts.
@MainActor
final class AgentDetail {
    let values: [String: Any]
    var metadata: [String: Any] { values["metadata"] as? [String: Any] ?? [:] }

    init(_ values: [String: Any]) { self.values = values }

    func validate(agentId: String, workspaceId: String?) throws {
        // Validate supplied identity before publishing or reusing a detail.
        if let id = values["id"] as? String, id != agentId { throw AgentDetailError.identityMismatch }
        if let workspaceId, let returned = values["workspaceId"] as? String, returned != workspaceId {
            throw AgentDetailError.identityMismatch
        }
    }
}

enum AgentDetailError: LocalizedError {
    case identityMismatch
    case invalidResponse

    var errorDescription: String? { "The server returned an incomplete agent response. Please retry." }
}

/// One instance belongs to one BackendSession/connection. Loads coalesce and
/// remain reusable after completion, including route validation and late cards.
/// Consumers retain for an activation; the last release expires its freshness.
/// Explicit refreshes bypass a completed cache and revalidate an older flight
/// through its coalesced trailing read (proposal mutations use this path).
@MainActor @Observable
final class AgentDetailStore {
    private struct Patch {
        let revision: Int
        let value: Any
    }

    private final class Entry {
        var task: Task<AgentDetail, Error>?
        var requestID = UUID()
        var fresh = false
        var invalidation = 0
        var activationGeneration = 0
        var revision = 0
        var fields: [String: Patch] = [:]
        var metadata: [String: Patch] = [:]
        var consumers: Set<UUID> = []
        var workspaceId: String?
    }

    @ObservationIgnored private let connection: any ConnectionManagerRouting
    @ObservationIgnored private var entries: [String: Entry] = [:]
    private var snapshots: [String: AgentDetail] = [:]
    @ObservationIgnored private var eventHandlerID: UUID?
    @ObservationIgnored private var connectionObserver: AnyCancellable?
    @ObservationIgnored private var connectionState: ConnectionState
    private(set) var connectionEpoch = 0

    init(connection: any ConnectionManagerRouting) {
        self.connection = connection
        connectionState = connection.connectionState
        eventHandlerID = connection.onEvent { [weak self] _, params in
            self?.handleEvent(params)
        }
        connectionObserver = connection.connectionStatePublisher.sink { [weak self] state in
            self?.connectionChanged(state)
        }
    }

    isolated deinit {
        if let eventHandlerID { connection.removeEventHandler(id: eventHandlerID) }
        for entry in entries.values { entry.task?.cancel() }
    }

    func cached(agentId: String) -> AgentDetail? { snapshots[agentId] }

    func retain(agentId: String) -> UUID {
        let consumer = UUID()
        entry(for: agentId).consumers.insert(consumer)
        return consumer
    }

    func release(agentId: String, consumer: UUID) {
        guard let entry = entries[agentId], entry.consumers.remove(consumer) != nil else { return }
        if entry.consumers.isEmpty {
            entry.fresh = false
            entry.activationGeneration &+= 1
        }
    }

    func load(agentId: String, workspaceId: String? = nil, refresh: Bool = false) async throws -> AgentDetail {
        try Task.checkCancellation()
        let entry = entry(for: agentId)
        if refresh, entry.task != nil { invalidate(agentId: agentId) }
        if entry.task == nil, entry.fresh, !refresh, let detail = snapshots[agentId] {
            try detail.validate(agentId: agentId, workspaceId: workspaceId)
            return detail
        }
        if entry.task == nil {
            let requestID = UUID()
            entry.requestID = requestID
            entry.workspaceId = workspaceId
            let epoch = connectionEpoch
            entry.task = Task { try await self.read(agentId: agentId, entry: entry, requestID: requestID, epoch: epoch) }
        }
        guard let task = entry.task else { throw CancellationError() }
        let epoch = connectionEpoch
        let received = try await task.value
        try Task.checkCancellation()
        guard epoch == self.connectionEpoch else { throw CancellationError() }
        let detail = snapshots[agentId] ?? received
        try detail.validate(agentId: agentId, workspaceId: workspaceId)
        return detail
    }

    /// Repeated invalidations during a read request at most one trailing read.
    /// More changes during that trailing read leave the entry stale for the next
    /// consumer, instead of keeping an unbounded reconciliation loop alive.
    func invalidate(agentId: String) {
        guard let entry = entries[agentId] else { return }
        entry.fresh = false
        entry.invalidation &+= 1
    }

    func updateMetadata(agentId: String, fields: [String: Any]) {
        patch(agentId: agentId, fields: [:], metadata: fields)
    }

    func reset() {
        connectionEpoch &+= 1
        for entry in entries.values {
            entry.task?.cancel()
            entry.task = nil
            entry.requestID = UUID()
            entry.fresh = false
            entry.fields = [:]
            entry.metadata = [:]
        }
        snapshots = [:]
    }

    private func entry(for agentId: String) -> Entry {
        if let entry = entries[agentId] { return entry }
        let entry = Entry()
        entries[agentId] = entry
        return entry
    }

    private func read(agentId: String, entry: Entry, requestID: UUID, epoch: Int) async throws -> AgentDetail {
        let activationGeneration = entry.activationGeneration
        defer { if entry.requestID == requestID { entry.task = nil } }
        do {
            for round in 0..<2 {
                let invalidation = entry.invalidation
                let revision = entry.revision
                // Agent ids are backend-wide. Do not accidentally scope a
                // watched child to its parent's workspace; validate per caller.
                var params: [String: Any] = ["agentId": agentId]
                if let workspaceId = entry.workspaceId { params["workspaceId"] = workspaceId }
                let response = try await connection.request("agent.get", params: params)
                guard epoch == self.connectionEpoch, entry.requestID == requestID else { throw CancellationError() }
                guard let envelope = response as? [String: Any],
                      let values = envelope["agent"] as? [String: Any], !values.isEmpty else {
                    throw AgentDetailError.invalidResponse
                }
                let received = AgentDetail(values)
                try received.validate(agentId: agentId, workspaceId: entry.workspaceId)
                let detail = applyingPatches(to: received, entry: entry, after: revision)
                if invalidation != entry.invalidation {
                    if round == 0 { continue }
                    throw CancellationError()
                }
                snapshots[agentId] = detail
                entry.fresh = invalidation == entry.invalidation && activationGeneration == entry.activationGeneration
                return detail
            }
            throw AgentDetailError.invalidResponse
        } catch {
            guard epoch == connectionEpoch, entry.requestID == requestID else { throw CancellationError() }
            entry.fresh = false
            throw error
        }
    }

    private func applyingPatches(to detail: AgentDetail, entry: Entry, after revision: Int) -> AgentDetail {
        var values = detail.values
        var metadata = detail.metadata
        for (key, patch) in entry.fields where patch.revision > revision { values[key] = patch.value }
        for (key, patch) in entry.metadata where patch.revision > revision { metadata[key] = patch.value }
        values["metadata"] = metadata
        return AgentDetail(values)
    }

    private func patch(agentId: String, fields: [String: Any], metadata: [String: Any]) {
        let entry = entry(for: agentId)
        entry.revision &+= 1
        for (key, value) in fields { entry.fields[key] = Patch(revision: entry.revision, value: value) }
        for (key, value) in metadata { entry.metadata[key] = Patch(revision: entry.revision, value: value) }
        if let detail = snapshots[agentId] {
            snapshots[agentId] = applyingPatches(to: detail, entry: entry, after: entry.revision - 1)
        }
    }

    private func connectionChanged(_ state: ConnectionState) {
        guard state != connectionState else { return }
        let wasConnected = connectionState == .connected
        connectionState = state
        if wasConnected || state == .connected { reset() }
    }

    private func handleEvent(_ params: Any) {
        guard let envelope = params as? [String: Any] else { return }
        let event = envelope["event"] as? [String: Any] ?? envelope
        guard let type = event["type"] as? String, let data = event["data"] as? [String: Any],
              let agentId = data["agentId"] as? String, let entry = entries[agentId] else { return }
        if let workspace = (data["workspaceId"] ?? event["workspaceId"]) as? String,
           let known = snapshots[agentId]?.values["workspaceId"] as? String ?? entry.workspaceId, workspace != known { return }
        if type == "agent:deleted" {
            entry.task?.cancel()
            entry.task = nil
            entry.requestID = UUID()
            entry.fresh = false
            snapshots[agentId] = nil
            return
        }
        guard type == "agent:updated" else { return }
        let metadata = data.filter { Self.metadataKeys.contains($0.key) }
        let fields = data.filter { Self.fieldKeys.contains($0.key) }
        patch(agentId: agentId, fields: fields, metadata: metadata)
        if Self.requiresReconciliation(data) {
            invalidate(agentId: agentId)
            if !entry.consumers.isEmpty, entry.task == nil {
                Task { _ = try? await self.load(agentId: agentId) }
            }
        }
    }

    static func requiresReconciliation(_ data: [String: Any]) -> Bool {
        data.keys.allSatisfy { !metadataKeys.contains($0) && !fieldKeys.contains($0) }
    }

    private static let metadataKeys: Set<String> = [
        "pendingQuestionsMessageId", "dismissedQuestionsMessageId", "lastSeenMessageId",
        "pendingProposals", "proposalResolutions", "specialist"
    ]
    private static let fieldKeys: Set<String> = ["name", "model", "provider", "status", "isStreaming", "isResponding", "turnInFlight"]
}
