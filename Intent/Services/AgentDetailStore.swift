import Combine
import Foundation
import Observation
import Synchronization

/// Only an agent.get response creates detail knowledge. Summary/list rows must
/// not seed this store: they omit fields such as pending proposal receipts.
@MainActor
final class AgentDetail {
    let values: [String: Any]
    /// Start order of the successful shared RPC that last supplied each marker.
    /// Patches preserve this provenance; joining callers must not replace it.
    let markerReadSequences: [String: Int]
    var metadata: [String: Any] { values["metadata"] as? [String: Any] ?? [:] }

    init(_ values: [String: Any], markerReadSequences: [String: Int] = [:]) {
        self.values = values
        self.markerReadSequences = markerReadSequences
    }

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
    let summaries = AgentSummaryStore()
    @ObservationIgnored private let requestLimiter = AgentDetailRequestLimiter()
    /// Cancellation can arrive off-actor while the shared request is suspended.
    /// Record it synchronously so a late reply cannot start work for a dead caller.
    nonisolated private final class LoadInterest: Sendable {
        let activation: Int?
        private let cancelled = Mutex(false)

        init(activation: Int?) { self.activation = activation }

        var isCancelled: Bool { cancelled.withLock { $0 } }

        func cancel() { cancelled.withLock { $0 = true } }
    }

    private struct Patch {
        let revision: Int
        let sequence: Int
        let value: Any
    }

    private struct PatchField: Hashable {
        let name: String
        let workspaceId: String?
    }

    private final class Entry {
        var task: Task<AgentDetail, Error>?
        var requestID = UUID()
        var fresh = false
        var invalidation = 0
        var activationGeneration = 0
        var revision = 0
        var fields: [PatchField: Patch] = [:]
        var metadata: [PatchField: Patch] = [:]
        var consumers: Set<UUID> = []
        var interests: [UUID: LoadInterest] = [:]
        var workspaceId: String?
    }

    @ObservationIgnored private let connection: any ConnectionManagerRouting
    @ObservationIgnored private var entries: [String: Entry] = [:]
    private var snapshots: [String: AgentDetail] = [:]
    @ObservationIgnored private var eventHandlerID: UUID?
    @ObservationIgnored private var connectionObserver: AnyCancellable?
    @ObservationIgnored private var connectionState: ConnectionState
    private(set) var connectionEpoch = 0
    @ObservationIgnored private var stateSequence = 0

    /// One backend-local order for actual read starts and notification receipt.
    /// It survives resets so an old reply can never acquire a newer boundary.
    func nextStateSequence() -> Int {
        stateSequence &+= 1
        return stateSequence
    }

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
        try await load(agentId: agentId, workspaceId: workspaceId, refresh: refresh, activation: nil)
    }

    private func load(agentId: String, workspaceId: String?, refresh: Bool, activation: Int?) async throws -> AgentDetail {
        try Task.checkCancellation()
        let entry = entry(for: agentId)
        if entry.task?.isCancelled == true {
            entry.task = nil
            entry.requestID = UUID()
            entry.fresh = false
        }
        if let activation {
            guard activation == entry.activationGeneration, !entry.consumers.isEmpty else { throw CancellationError() }
        }
        if refresh, entry.task != nil { invalidate(agentId: agentId) }
        if entry.task == nil, entry.fresh, !refresh, let detail = snapshots[agentId] {
            try detail.validate(agentId: agentId, workspaceId: workspaceId)
            return detail
        }
        let interestID = UUID()
        let interest = LoadInterest(activation: activation)
        entry.interests[interestID] = interest
        defer { entry.interests[interestID] = nil }
        if entry.task == nil {
            let requestID = UUID()
            entry.requestID = requestID
            let epoch = connectionEpoch
            entry.task = Task { try await self.read(agentId: agentId, entry: entry, requestID: requestID, epoch: epoch) }
        }
        guard let task = entry.task else { throw CancellationError() }
        let epoch = connectionEpoch
        let received = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            interest.cancel()
            Task { @MainActor [weak self] in
                guard let self, !hasInterest(in: entry) else { return }
                entry.task?.cancel()
            }
        }
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
        summaries.reset()
        for entry in entries.values {
            entry.task?.cancel()
            entry.task = nil
            entry.interests = [:]
            entry.requestID = UUID()
            entry.fresh = false
            entry.fields = [:]
            entry.metadata = [:]
            entry.workspaceId = nil
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
        defer { if entry.requestID == requestID { entry.task = nil } }
        do {
            try await requestLimiter.acquire()
            defer { requestLimiter.release() }
            for round in 0..<2 {
                try Task.checkCancellation()
                guard hasInterest(in: entry) else { throw CancellationError() }
                let activationGeneration = entry.activationGeneration
                let invalidation = entry.invalidation
                let revision = entry.revision
                let sequence = nextStateSequence()
                let summaryBoundary = summaries.beginRead()
                // Agent ids are backend-wide. Do not accidentally scope a
                // watched child to its parent's workspace; validate per caller.
                let response = try await connection.request("agent.get", params: ["agentId": agentId])
                try Task.checkCancellation()
                guard epoch == self.connectionEpoch, entry.requestID == requestID, hasInterest(in: entry) else { throw CancellationError() }
                guard let envelope = response as? [String: Any],
                      let values = envelope["agent"] as? [String: Any], !values.isEmpty else {
                    throw AgentDetailError.invalidResponse
                }
                let received = receivedDetail(values, previous: snapshots[agentId], sequence: sequence)
                try received.validate(agentId: agentId, workspaceId: nil)
                let detail = applyingPatches(to: received, entry: entry, after: revision)
                if invalidation != entry.invalidation {
                    if round == 0 { continue }
                    throw CancellationError()
                }
                snapshots[agentId] = detail
                summaries.seed([detail.values], since: summaryBoundary)
                entry.workspaceId = detail.values["workspaceId"] as? String
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

    private func hasInterest(in entry: Entry) -> Bool {
        if !entry.consumers.isEmpty { return true }
        // Public loads (route validation, explicit refresh) do not need a lease.
        // Event reconciliation belongs only to the activation that requested it.
        return entry.interests.values.contains { !$0.isCancelled && $0.activation == nil }
    }

    private func receivedDetail(_ values: [String: Any], previous: AgentDetail?, sequence: Int) -> AgentDetail {
        var values = values
        var metadata = values["metadata"] as? [String: Any] ?? [:]
        let workspace = values["workspaceId"] as? String
        let previous = workspace == (previous?.values["workspaceId"] as? String) ? previous : nil
        var boundaries = previous?.markerReadSequences ?? [:]
        for field in Self.markerKeys {
            if metadata[field] is String {
                if workspace?.isEmpty == false { boundaries[field] = sequence }
            } else {
                // Omission/null cannot erase a known marker. Explicit "" can.
                metadata[field] = previous?.metadata[field] as? String
            }
        }
        values["metadata"] = metadata
        return AgentDetail(values, markerReadSequences: boundaries)
    }

    private func applyingPatches(to detail: AgentDetail, entry: Entry, after revision: Int) -> AgentDetail {
        var values = detail.values
        var metadata = detail.metadata
        let workspaceId = values["workspaceId"] as? String
        for (field, patch) in entry.fields.sorted(by: { $0.value.revision < $1.value.revision })
            where patch.revision > revision && (field.workspaceId == nil || field.workspaceId == workspaceId) {
            values[field.name] = patch.value
        }
        for (field, patch) in entry.metadata.sorted(by: { $0.value.revision < $1.value.revision })
            where field.workspaceId == nil || field.workspaceId == workspaceId {
            let isNewer = Self.markerKeys.contains(field.name)
                ? patch.sequence > (detail.markerReadSequences[field.name] ?? 0)
                : patch.revision > revision
            guard isNewer else { continue }
            metadata[field.name] = patch.value
        }
        values["metadata"] = metadata
        return AgentDetail(values, markerReadSequences: detail.markerReadSequences)
    }

    private func patch(agentId: String, fields: [String: Any], metadata: [String: Any], workspaceId: String? = nil) {
        let entry = entry(for: agentId)
        entry.revision &+= 1
        let sequence = nextStateSequence()
        for (key, value) in fields {
            entry.fields[PatchField(name: key, workspaceId: workspaceId)] = Patch(revision: entry.revision, sequence: sequence, value: value)
        }
        for (key, value) in metadata {
            guard !Self.markerKeys.contains(key) || value is String else { continue }
            entry.metadata[PatchField(name: key, workspaceId: workspaceId)] = Patch(revision: entry.revision, sequence: sequence, value: value)
        }
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
        summaries.handleEvent(params)
        guard let envelope = params as? [String: Any] else { return }
        let event = envelope["event"] as? [String: Any] ?? envelope
        guard let type = event["type"] as? String, let data = event["data"] as? [String: Any],
              let agentId = data["agentId"] as? String, let entry = entries[agentId] else { return }
        if let workspace = (data["workspaceId"] ?? event["workspaceId"]) as? String,
           let known = snapshots[agentId]?.values["workspaceId"] as? String ?? entry.workspaceId, workspace != known { return }
        if type == "agent:deleted" {
            entry.task?.cancel()
            entry.task = nil
            entry.interests = [:]
            entry.requestID = UUID()
            entry.fresh = false
            snapshots[agentId] = nil
            return
        }
        guard type == "agent:updated" else { return }
        let metadata = data.filter { Self.metadataKeys.contains($0.key) }
        let fields = data.filter { Self.fieldKeys.contains($0.key) }
        patch(agentId: agentId, fields: fields, metadata: metadata, workspaceId: (data["workspaceId"] ?? event["workspaceId"]) as? String)
        if Self.requiresReconciliation(data) {
            invalidate(agentId: agentId)
            if !entry.consumers.isEmpty, entry.task == nil {
                let activation = entry.activationGeneration
                let epoch = connectionEpoch
                Task { [weak self] in
                    guard let self, connectionEpoch == epoch else { return }
                    _ = try? await load(agentId: agentId, workspaceId: nil, refresh: false, activation: activation)
                }
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
    private static let markerKeys: Set<String> = ["pendingQuestionsMessageId", "dismissedQuestionsMessageId", "lastSeenMessageId"]
    private static let fieldKeys: Set<String> = ["name", "model", "provider", "status", "isStreaming", "isResponding", "turnInFlight"]
}
