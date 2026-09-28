import Foundation
import Observation

@MainActor
@Observable
final class ConversationWatchedAgents {
    var watchedAgentIds: [String] = []
    var delegationGroupStatus: (completed: Int, total: Int)?
    var isWaitingForAgents = false
    private(set) var groups: [WatchedAgentGroup] = []
    private(set) var errors: [String: String] = [:]
    var watchedAgents: [AgentSession] {
        get { rows.map(\.agent) }
        set { localAgents = Dictionary(newValue.map { ($0.id, $0) }) { _, last in last } }
    }
    var rows: [WatchedAgentRow] { watchedAgentIds.map(row) }

    @ObservationIgnored private let commands: ConversationCommands
    private var readGeneration = 0
    private var localAgents: [String: AgentSession] = [:]
    @ObservationIgnored private var visible: [UUID: Set<String>] = [:]
    @ObservationIgnored private var loads: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var summaryObserver: UUID?
    private var summaries: AgentSummaryStore { commands.agentDetails.summaries }

    init(commands: ConversationCommands) {
        self.commands = commands
        summaryObserver = summaries.observe { [weak self] id in
            guard let self, watchedAgentIds.contains(id) else { return }
            reconcileVisibility()
        }
    }

    isolated deinit {
        for load in loads.values { load.task.cancel() }
        if let summaryObserver { summaries.removeObserver(summaryObserver) }
    }

    func invalidateReads() {
        readGeneration &+= 1
        for load in loads.values { load.task.cancel() }
        loads = [:]
    }

    func fetchSubscriptions(
        agentId: String,
        workspaceId: String,
        awaitAuthority: () async -> Bool = { true },
        isCurrent: () -> Bool = { true }
    ) async {
        let generation = readGeneration
        do {
            guard let snapshot = try await commands.fetchSubscriptions(agentId: agentId, workspaceId: workspaceId) else { return }
            guard !Task.isCancelled, generation == readGeneration, isCurrent() else { return }
            guard await awaitAuthority(), !Task.isCancelled, generation == readGeneration, isCurrent() else { return }
            watchedAgentIds = snapshot.watchedAgentIds
            groups = snapshot.groups
            isWaitingForAgents = !watchedAgentIds.isEmpty
            delegationGroupStatus = snapshot.delegationGroupStatus
            summaries.seedStatuses(snapshot.agentStatuses, since: snapshot.summaryBoundary)
            reconcileVisibility()
        } catch {
            AppLog.conversation.error("[ConversationStore] Failed to fetch subscriptions: \(error)")
        }
    }

    func row(_ agentId: String) -> WatchedAgentRow {
        let values = summaries.cached(agentId: agentId)
        let name = values["name"] as? String
        let workspace = (values["workspaceId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var display = values
        display["id"] = agentId
        display["name"] = name ?? String(agentId.prefix(Constants.Conversation.AgentWaiting.fallbackAgentIdMaximumLength)) + "..."
        display["status"] = values["status"] as? String ?? "unknown"
        guard let parsed = AgentSession.parseAgent(display) else {
            preconditionFailure("Watched display rows always supply an ID and name")
        }
        let agent = name == nil ? localAgents[agentId] ?? parsed : parsed
        return WatchedAgentRow(
            agent: agent,
            workspaceId: workspace,
            hasSummary: name?.isEmpty == false && workspace != nil,
            isCompleted: groups.contains { $0.completedAgentIds.contains(agentId) },
            isDeleted: agent.status == "deleted" || groups.contains { $0.deletedAgentIds.contains(agentId) }
        )
    }

    /// The view reports actual viewport intersection, not LazyVStack prefetch.
    /// Each window owns its own interest; one disappearing window cannot cancel another.
    func setVisible(_ agentId: String, visible isVisible: Bool, consumer: UUID) {
        if isVisible, visible[consumer]?.contains(agentId) != true { errors[agentId] = nil }
        if isVisible { visible[consumer, default: []].insert(agentId) } else { visible[consumer]?.remove(agentId) }
        reconcileVisibility()
    }

    func releaseVisibility(consumer: UUID) {
        visible[consumer] = nil
        reconcileVisibility()
    }

    /// Selecting an unresolved placeholder is an explicit detail interest. It
    /// shares the very same backend/agent flight with visible rows and routes.
    func selectedAgent(_ agentId: String) async -> WatchedAgentRow? {
        let generation = readGeneration
        guard watchedAgentIds.contains(agentId), !row(agentId).isDeleted else { return nil }
        do {
            if !row(agentId).hasSummary { try await loadMissing(agentId) }
            guard !Task.isCancelled, generation == readGeneration, watchedAgentIds.contains(agentId) else { return nil }
            let selected = row(agentId)
            return selected.hasSummary && !selected.isDeleted ? selected : nil
        } catch {
            if !Task.isCancelled, generation == readGeneration { errors[agentId] = error.localizedDescription }
            return nil
        }
    }

    func retry(_ agentId: String) {
        errors[agentId] = nil
        reconcileVisibility()
    }

    private func reconcileVisibility() {
        let interested = Set(visible.values.flatMap { $0 }).intersection(watchedAgentIds)
        for (id, load) in loads where !interested.contains(id) || row(id).isDeleted || row(id).hasSummary {
            load.task.cancel()
            loads[id] = nil
        }
        for id in interested.sorted() where loads[id] == nil && errors[id] == nil && !row(id).hasSummary && !row(id).isDeleted {
            let generation = readGeneration
            let token = UUID()
            let task = Task { [weak self] in
                guard let self, generation == readGeneration, !Task.isCancelled else { return }
                defer { if loads[id]?.id == token { loads[id] = nil } }
                do {
                    try await loadMissing(id)
                } catch {
                    if !Task.isCancelled, generation == readGeneration { errors[id] = error.localizedDescription }
                }
            }
            loads[id] = (token, task)
        }
    }

    private func loadMissing(_ agentId: String) async throws {
        let detail = try await commands.agentDetails.load(agentId: agentId, workspaceId: row(agentId).workspaceId)
        try Task.checkCancellation()
        guard detail.values["id"] as? String == agentId,
              let workspace = detail.values["workspaceId"] as? String, !workspace.isEmpty,
              let name = detail.values["name"] as? String, !name.isEmpty else {
            commands.agentDetails.invalidate(agentId: agentId)
            throw AgentDetailError.invalidResponse
        }
        errors[agentId] = nil
    }

    // Enriched activity is display data, never a reason to discover an offscreen agent.
    func handleActivity(agentId: String, lastAgentResponse: String?, digest: String?) {
        guard watchedAgentIds.contains(agentId), let agent = localAgents[agentId] else { return }
        localAgents[agentId] = agent.applyingPreview(lastAgentResponse: lastAgentResponse, digest: digest)
    }

    func handleStatusChange(agentId: String) {
        guard watchedAgentIds.contains(agentId) else { return }
        reconcileVisibility()
    }

    func handleStreamEnd(agentId: String) { handleStatusChange(agentId: agentId) }

    func cancelSubscriptions(agentId: String, workspaceId: String) async {
        let generation = readGeneration
        do {
            try await commands.cancelSubscriptions(agentId: agentId, workspaceId: workspaceId)
            guard !Task.isCancelled, generation == readGeneration else { return }
            reset()
        } catch {
            AppLog.conversation.error("[ConversationStore] Failed to cancel subscriptions: \(error)")
        }
    }

    func stopAgents(agentIds: [String], parentAgentId: String, workspaceId: String) async {
        await cancelSubscriptions(agentId: parentAgentId, workspaceId: workspaceId)
        for agentId in [parentAgentId] + agentIds {
            do { try await commands.stop(agentId: agentId) } catch { AppLog.conversation.error("[ConversationStore] Failed to stop agent \(agentId): \(error)") }
        }
    }

    func reset() {
        invalidateReads()
        watchedAgentIds = []
        delegationGroupStatus = nil
        isWaitingForAgents = false
        groups = []
        localAgents = [:]
        visible = [:]
        errors = [:]
    }
}
