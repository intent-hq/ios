import Foundation
import Observation

@MainActor
@Observable
final class ConversationWatchedAgents {
    var watchedAgentIds: [String] = []
    var delegationGroupStatus: (completed: Int, total: Int)?
    var isWaitingForAgents = false
    var watchedAgents: [AgentSession] = []

    @ObservationIgnored private let commands: ConversationCommands
    @ObservationIgnored private let now: () -> Date
    private var workspaceId: String?
    private var readGeneration = 0
    private var lastRefresh: [String: Date] = [:]

    init(commands: ConversationCommands, now: @escaping () -> Date = Date.init) {
        self.commands = commands
        self.now = now
    }

    func invalidateReads() { readGeneration &+= 1 }

    func fetchSubscriptions(
        agentId: String,
        workspaceId: String,
        awaitAuthority: () async -> Bool = { true },
        isCurrent: () -> Bool = { true }
    ) async {
        let generation = readGeneration
        do {
            guard let snapshot = try await commands.fetchSubscriptions(
                agentId: agentId,
                workspaceId: workspaceId
            ) else { return }
            guard !Task.isCancelled, generation == readGeneration, isCurrent() else { return }
            guard await awaitAuthority(), !Task.isCancelled, generation == readGeneration, isCurrent() else { return }
            self.workspaceId = workspaceId
            watchedAgentIds = snapshot.watchedAgentIds
            isWaitingForAgents = !watchedAgentIds.isEmpty
            delegationGroupStatus = snapshot.delegationGroupStatus
            await fetchDetails { generation == self.readGeneration && isCurrent() }
        } catch {
            AppLog.conversation.error(
                "[ConversationStore] Failed to fetch subscriptions: \(error)"
            )
        }
    }

    func cancelSubscriptions(agentId: String, workspaceId: String) async {
        do {
            try await commands.cancelSubscriptions(agentId: agentId, workspaceId: workspaceId)
            invalidateReads()
            watchedAgentIds = []
            isWaitingForAgents = false
            delegationGroupStatus = nil
            watchedAgents = []
        } catch {
            AppLog.conversation.error(
                "[ConversationStore] Failed to cancel subscriptions: \(error)"
            )
        }
    }

    func handleStatusChange(agentId: String) {
        guard watchedAgentIds.contains(agentId) else { return }
        refresh(agentId: agentId)
    }

    func handleActivity(
        agentId: String,
        lastAgentResponse: String?,
        digest: String?
    ) {
        guard watchedAgentIds.contains(agentId) else { return }
        if let index = watchedAgents.firstIndex(where: { $0.id == agentId }) {
            if lastAgentResponse != nil || digest != nil {
                watchedAgents[index] = watchedAgents[index].applyingPreview(
                    lastAgentResponse: lastAgentResponse,
                    digest: digest
                )
            }
            return
        }
        let currentDate = now()
        if let refreshedAt = lastRefresh[agentId],
           currentDate.timeIntervalSince(refreshedAt)
               < Constants.Conversation.AgentWaiting.activityRefreshThrottle { return }
        lastRefresh[agentId] = currentDate
        refresh(agentId: agentId)
    }

    func handleStreamEnd(agentId: String) {
        guard watchedAgentIds.contains(agentId) else { return }
        lastRefresh.removeValue(forKey: agentId)
        refresh(agentId: agentId)
    }

    func stopAgents(
        agentIds: [String],
        parentAgentId: String,
        workspaceId: String
    ) async {
        await cancelSubscriptions(agentId: parentAgentId, workspaceId: workspaceId)
        do {
            try await commands.stop(agentId: parentAgentId)
        } catch {
            AppLog.conversation.error(
                "[ConversationStore] Failed to stop parent agent: \(error)"
            )
        }
        for agentId in agentIds {
            do {
                try await commands.stop(agentId: agentId)
            } catch {
                AppLog.conversation.error(
                    "[ConversationStore] Failed to stop agent \(agentId): \(error)"
                )
            }
        }
    }

    func reset() {
        invalidateReads()
        watchedAgentIds = []
        delegationGroupStatus = nil
        isWaitingForAgents = false
        watchedAgents = []
        workspaceId = nil
        lastRefresh.removeAll()
    }

    private func refresh(agentId: String) {
        let generation = readGeneration
        Task { @MainActor [weak self] in
            guard let self, generation == readGeneration else { return }
            do {
                guard let updated = try await commands.fetchAgent(agentId: agentId) else { return }
                guard !Task.isCancelled, generation == readGeneration else { return }
                if !updated.isActive {
                    watchedAgents.removeAll { $0.id == agentId }
                    watchedAgentIds.removeAll { $0 == agentId }
                    isWaitingForAgents = !watchedAgentIds.isEmpty
                    if watchedAgentIds.isEmpty { delegationGroupStatus = nil }
                } else if let index = watchedAgents.firstIndex(where: { $0.id == agentId }) {
                    watchedAgents[index] = updated
                } else {
                    watchedAgents.append(updated)
                }
                AppLog.conversation.debug(
                    "[ConversationStore] Updated watched agent: \(updated.name): "
                        + "\(updated.displayMessage ?? "nil")"
                )
            } catch {
                AppLog.conversation.error(
                    "[ConversationStore] Failed to fetch watched agent \(agentId): \(error)"
                )
            }
        }
    }

    private func fetchDetails(isCurrent: () -> Bool) async {
        guard let workspaceId else { return }
        guard !watchedAgentIds.isEmpty else {
            watchedAgents = []
            return
        }
        do {
            let result = try await commands.listAgents(
                workspaceId: workspaceId,
                watchedAgentIds: watchedAgentIds
            )
            guard !Task.isCancelled, isCurrent(), case let .sessions(agents) = result else { return }
            AppLog.conversation.debug(
                "[ConversationStore] Fetched \(agents.count) watched agents: "
                    + "\(agents.map { "\($0.name): \($0.displayMessage ?? "nil")" })"
            )
            watchedAgents = agents
        } catch {
            AppLog.conversation.error(
                "[ConversationStore] Failed to fetch watched agent details: \(error)"
            )
        }
    }
}
