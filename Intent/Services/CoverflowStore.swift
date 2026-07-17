import Foundation
import Combine
import SwiftUI

@MainActor
class CoverflowStore: ObservableObject {
    static let shared = CoverflowStore()

    /// Ordered agent queue — front (index 0) = most recently idle/completed.
    @Published var queue: [CoverflowAgent] = []

    /// Agent IDs that finished (became idle) but haven't been viewed/focused yet.
    @Published var unreviewedAgentIds: Set<String> = []

    /// The agent ID currently focused/visible in the card pager.
    @Published var focusedAgentId: String?

    /// Count of unreviewed agents — for badge display.
    var finishedCount: Int { unreviewedAgentIds.count }

    /// In-memory set of banished agent IDs (removed from queue entirely).
    private var banishedIds: Set<String> = []

    /// Agents soft-removed from queue by user. They come back if they start streaming again.
    private var removedIds: Set<String> = []

    /// Agent IDs that we know are currently streaming (tracked via events)
    @Published private var streamingAgentIds: Set<String> = []

    /// Agent IDs that are idle but waiting for sub-agents to finish
    @Published private var waitingAgentIds: Set<String> = []

    /// Cached ConversationViewModels keyed by agentId — prevents conversation reload on queue changes.
    private var conversationViewModels: [String: ConversationViewModel] = [:]

    private var eventHandlerId: UUID?
    private var connectionObserver: AnyCancellable?

    private init() {
        observeConnection()
    }

    /// Test-only initializer that skips connection observation
    init(forTesting: Bool) {}

    // MARK: - Computed properties

    /// Color pairs for background animation — only from agents currently streaming/working.
    var activeAgentColors: [(repoColor: Color, agentColor: Color)] {
        queue
            .filter { isAgentStreaming($0.id) }
            .map { ($0.repoColor, $0.agentColor) }
    }

    /// Check if an agent is currently streaming or waiting for sub-agents (based on real-time events, not persisted status).
    func isAgentStreaming(_ agentId: String) -> Bool {
        let inSet = streamingAgentIds.contains(agentId)
        let waiting = waitingAgentIds.contains(agentId)
        let vmStreaming = conversationViewModels[agentId]?.isStreaming ?? false
        let result = inSet || waiting || vmStreaming
        if result {
            print("[CoverflowStore] isAgentStreaming(\(agentId.prefix(8))...) = \(result) (inSet=\(inSet) waiting=\(waiting) vm=\(vmStreaming))")
        }
        return result
    }

    // MARK: - Connection observation

    private func observeConnection() {
        connectionObserver = ConnectionManager.shared.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                if state == .connected {
                    Task { await self?.onConnected() }
                }
            }
    }

    private func onConnected() async {
        print("[CoverflowStore] onConnected called")
        await fetchAllAgents()
        subscribeToEvents()
    }

    // MARK: - Fetch agents across workspaces

    func fetchAllAgents() async {
        let workspaces = WorkspaceStore.shared.workspaces
            .filter {
                let status = $0.status?.lowercased() ?? ""
                return status != "archived" && status != "deleted"
            }

        var allAgents: [CoverflowAgent] = []

        for workspace in workspaces {
            do {
                let result = try await ConnectionManager.shared.request(
                    "agent.list",
                    params: ["workspaceId": workspace.id, "includeCompleted": false]
                )
                if let dict = result as? [String: Any],
                   let items = dict["agents"] as? [[String: Any]] {
                    let agents = items.compactMap { AgentSession.parseAgent($0) }
                    for agent in agents {
                        // Strict filtering: only foreground, user-created agents
                        let statusLower = agent.status.lowercased()
                        guard !agent.isBackground,
                              agent.createdByAgentId == nil,
                              statusLower != "completed" && statusLower != "failed" && statusLower != "error",
                              !banishedIds.contains(agent.id),
                      !removedIds.contains(agent.id) else { continue }
                        let coverflowAgent = CoverflowAgent(
                            id: agent.id,
                            agent: agent,
                            workspaceId: workspace.id,
                            repositoryName: workspace.repositoryName ?? "unknown",
                            repositoryOwner: workspace.repositoryOwner,
                            workspaceTitle: workspace.title
                        )
                        allAgents.append(coverflowAgent)
                    }
                }
            } catch {
                print("[CoverflowStore] Failed to fetch agents for workspace \(workspace.id): \(error)")
            }
        }

        // Filter to last 24 hours (unless currently streaming/responding).

        // Sort by most-recently-active-first, then take top 10
        allAgents.sort { a, b in
            let aStatus = a.agent.status.lowercased()
            let bStatus = b.agent.status.lowercased()
            let aActive = aStatus == "responding" || aStatus == "streaming" || aStatus == "processing"
            let bActive = bStatus == "responding" || bStatus == "streaming" || bStatus == "processing"

            // Active agents first
            if aActive != bActive { return aActive }

            // Then by most recent timestamp
            let dateA = a.bestTimestamp ?? .distantPast
            let dateB = b.bestTimestamp ?? .distantPast
            return dateA > dateB
        }
        // Filter to agents active in last 24 hours (unless currently streaming/responding)
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        let filtered = allAgents.filter { agent in
            let statusLower = agent.agent.status.lowercased()
            let isActive = statusLower == "responding" || statusLower == "streaming" || statusLower == "processing"
                || agent.agent.isStreaming || agent.agent.isResponding || agent.agent.isProcessing
            if isActive { return true }
            guard let ts = agent.bestTimestamp else { return false }
            return ts > cutoff
        }

        // Seed streaming status from current agent states
        var initialStreaming = Set<String>()
        for agent in filtered {
            let statusLower = agent.agent.status.lowercased()
            if statusLower == "responding" || statusLower == "streaming" || statusLower == "processing"
                || agent.agent.isStreaming || agent.agent.isResponding || agent.agent.isProcessing {
                initialStreaming.insert(agent.id)
            }
        }
        // Merge with existing streaming IDs (don't clear ones that came from events)
        streamingAgentIds.formUnion(initialStreaming)

        // Preserve existing queue ordering — only add new agents and remove stale ones
        if queue.isEmpty {
            // First load — use the sorted order
            queue = filtered
        } else {
            // Update existing agents in-place (preserve position)
            var updatedQueue: [CoverflowAgent] = []
            for existing in queue {
                if let updated = filtered.first(where: { $0.id == existing.id }) {
                    updatedQueue.append(updated)
                }
                // If agent is no longer in filtered, it drops out
            }
            // Add new agents that weren't in the existing queue (append to end)
            for agent in filtered {
                if !updatedQueue.contains(where: { $0.id == agent.id }) {
                    updatedQueue.append(agent)
                }
            }
            queue = updatedQueue
            resortQueue()
        }

        // Clean up cached ViewModels for agents no longer in queue
        let queueIds = Set(queue.map { $0.id })
        conversationViewModels = conversationViewModels.filter { queueIds.contains($0.key) }
    }

    // MARK: - Queue management

    /// Returns a cached ConversationViewModel for the given agent, creating one if needed.
    func conversationViewModel(for agent: CoverflowAgent) -> ConversationViewModel {
        if let existing = conversationViewModels[agent.id] {
            return existing
        }
        let vm = ConversationViewModel(
            agentId: agent.id,
            workspaceId: agent.workspaceId,
            agentName: agent.name
        )
        conversationViewModels[agent.id] = vm
        return vm
    }

    /// Removes an agent from the queue entirely (UI-only, in-memory).
    func banish(agentId: String) {
        banishedIds.insert(agentId)
        conversationViewModels.removeValue(forKey: agentId)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            queue.removeAll { $0.id == agentId }
        }
    }

    /// Soft-remove: agent leaves queue but can return if it starts streaming again.
    func removeFromQueue(agentId: String) {
        removedIds.insert(agentId)
        unreviewedAgentIds.remove(agentId)
        conversationViewModels.removeValue(forKey: agentId)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
            queue.removeAll { $0.id == agentId }
        }
    }

    /// Mark an agent as reviewed (removes from badge count).
    func markReviewed(agentId: String) {
        unreviewedAgentIds.remove(agentId)
    }

    // MARK: - Event subscription

    private func subscribeToEvents() {
        print("[CoverflowStore] subscribeToEvents called, existing handler: \(eventHandlerId != nil)")
        // Remove old handler to prevent accumulation on reconnect
        if let handlerId = eventHandlerId {
            ConnectionManager.shared.removeEventHandler(id: handlerId)
        }

        eventHandlerId = ConnectionManager.shared.onEvent { [weak self] method, params in
            Task { @MainActor [weak self] in
                self?.handleEvent(params)
            }
        }
    }

    private func handleEvent(_ params: Any) {
        guard let dict = params as? [String: Any] else { return }

        // Events from websocket-event-bridge are wrapped:
        // { subscriptionId, event: { type, workspaceId, timestamp, data } }
        let event: [String: Any]
        if let innerEvent = dict["event"] as? [String: Any] {
            event = innerEvent
        } else {
            event = dict
        }

        guard let eventType = event["type"] as? String else { return }

        // agentId may be at top level of event OR inside event["data"]
        let agentId = event["agentId"] as? String
            ?? (event["data"] as? [String: Any])?["agentId"] as? String
        let workspaceId = event["workspaceId"] as? String

        print("[CoverflowStore] handleEvent: type=\(eventType) agentId=\(agentId ?? "nil")")

        switch eventType {
        case "agent:idle":
            // Agent became idle — mark as unreviewed if it was streaming, but don't
            // reorder the queue. Badge count is sufficient notification.
            if let agentId = agentId {
                let wasStreaming = streamingAgentIds.contains(agentId)
                streamingAgentIds.remove(agentId)

                // Skip background agents and agents waiting for sub-agents
                let data = event["data"] as? [String: Any]
                let isBackground = data?["isBackground"] as? Bool ?? false
                let isWaitingForAgents = data?["isWaitingForAgents"] as? Bool ?? false

                if isWaitingForAgents {
                    // Agent is idle but waiting for sub-agents — show stars
                    waitingAgentIds.insert(agentId)
                } else {
                    // Agent truly idle — stop showing stars
                    waitingAgentIds.remove(agentId)
                }

                if wasStreaming && focusedAgentId != agentId && !isBackground && !isWaitingForAgents {
                    unreviewedAgentIds.insert(agentId)
                }
                // Re-fetch to update status display
                if let wsId = workspaceId {
                    // Check if workspace is archived before fetching
                    let ws = WorkspaceStore.shared.workspaces.first(where: { $0.id == wsId })
                    let wsStatus = ws?.status?.lowercased() ?? ""
                    if wsStatus == "archived" || wsStatus == "deleted" {
                        queue.removeAll { $0.workspaceId == wsId }
                    } else {
                        Task { await fetchAgentsForWorkspace(wsId) }
                    }
                }
                resortQueue()
                // Don't fetch for idle agents not in queue — they're not interesting
            }

        case "agent:status-changed":
            // Agent changed status — detect responding/streaming or idle/completed
            if let agentId = agentId {
                let newStatus = event["status"] as? String
                    ?? (event["data"] as? [String: Any])?["status"] as? String
                    ?? (event["data"] as? [String: Any])?["newStatus"] as? String
                let statusLower = newStatus?.lowercased() ?? ""

                print("[CoverflowStore] status-changed: agentId=\(agentId.prefix(8))... status=\(statusLower) streamingAgentIds=\(streamingAgentIds)")

                let wasStreaming = streamingAgentIds.contains(agentId)

                if statusLower == "responding" || statusLower == "streaming" || statusLower == "processing" {
                    if !banishedIds.contains(agentId) {
                        streamingAgentIds.insert(agentId)
                        removedIds.remove(agentId)
                    }
                } else if statusLower == "idle" || statusLower == "completed" || statusLower == "failed" || statusLower == "error" {
                    streamingAgentIds.remove(agentId)
                }
                // Resort so active agents bubble to front
                resortQueue()

                if statusLower == "completed" || statusLower == "failed" || statusLower == "error" {
                    // Don't promote completed/failed agents — they're stale
                    break
                }

                if let idx = queue.firstIndex(where: { $0.id == agentId }) {
                    // NOTE: Don't add to unreviewedAgentIds here.
                    // The agent:idle handler does this with the correct isWaitingForAgents check.
                    // agent:status-changed events don't include isWaitingForAgents in their payload.

                    // Only refetch on idle transition (to update timestamps/status display).
                    // Don't refetch during streaming — streamingAgentIds already tracks it
                    // and refetching causes queue mutations that make all cards re-render.
                    if statusLower == "idle" || statusLower == "completed" || statusLower == "failed" || statusLower == "error" {
                        if let wsId = workspaceId {
                            Task { await fetchAgentsForWorkspace(wsId) }
                        }
                    }
                } else if !banishedIds.contains(agentId) {
                    // Only fetch if the agent is becoming active (not idle/completed)
                    if statusLower == "responding" || statusLower == "streaming" || statusLower == "processing" {
                        Task { await fetchAllAgents() }
                    }
                }
            }

        case "agent:user-message:sent":
            break

        case let t where t.hasPrefix("agent:stream:"):
            // Agent is streaming — mark as active
            if let agentId = agentId, !banishedIds.contains(agentId) {
                print("[CoverflowStore] stream event: \(t) agentId=\(agentId.prefix(8))... streamingAgentIds after=\(streamingAgentIds)")
                if t == "agent:stream:end" {
                    // Stream ended — don't remove from streaming yet, wait for agent:idle
                    // (agent may start another stream immediately)
                } else {
                    streamingAgentIds.insert(agentId)
                    // Agent is actively streaming now, no longer just waiting
                    waitingAgentIds.remove(agentId)
                    removedIds.remove(agentId)
                }
                // If not in queue, fetch it
                if queue.firstIndex(where: { $0.id == agentId }) == nil {
                    if let wsId = workspaceId {
                        // Check if workspace is archived before fetching
                        let ws = WorkspaceStore.shared.workspaces.first(where: { $0.id == wsId })
                        let wsStatus = ws?.status?.lowercased() ?? ""
                        if wsStatus != "archived" && wsStatus != "deleted" {
                            Task { await fetchAgentsForWorkspace(wsId) }
                        }
                    } else {
                        Task { await fetchAllAgents() }
                    }
                }
            }

        case "agent:started", "agent:created":
            // New agent started — re-fetch to pick it up
            if let wsId = workspaceId {
                // Check if workspace is archived before fetching
                let ws = WorkspaceStore.shared.workspaces.first(where: { $0.id == wsId })
                let wsStatus = ws?.status?.lowercased() ?? ""
                if wsStatus != "archived" && wsStatus != "deleted" {
                    Task { await fetchAgentsForWorkspace(wsId) }
                }
            }

        case let t where t.hasPrefix("workspace:"):
            // Workspace status change — remove agents if workspace is archived/deleted
            if let wsId = workspaceId {
                let data = event["data"] as? [String: Any]
                let wsStatus = (data?["status"] as? String)?.lowercased() ?? ""
                if wsStatus == "archived" || wsStatus == "deleted" || eventType == "workspace:deleted" {
                    // Clean up agents from this workspace
                    let removedAgents = queue.filter { $0.workspaceId == wsId }
                    for agent in removedAgents {
                        streamingAgentIds.remove(agent.id)
                        waitingAgentIds.remove(agent.id)
                    }
                    queue.removeAll { $0.workspaceId == wsId }
                }
            }

        default:
            break
        }
    }

    // MARK: - Single workspace fetch (for incremental updates)

    private func fetchAgentsForWorkspace(_ workspaceId: String) async {
        guard let workspace = WorkspaceStore.shared.workspaces.first(where: { $0.id == workspaceId }) else { return }

        // Skip archived/deleted workspaces and remove their agents from queue
        let wsStatus = workspace.status?.lowercased() ?? ""
        guard wsStatus != "archived" && wsStatus != "deleted" else {
            queue.removeAll { $0.workspaceId == workspaceId }
            return
        }

        do {
            let result = try await ConnectionManager.shared.request(
                "agent.list",
                params: ["workspaceId": workspaceId, "includeCompleted": false]
            )
            guard let dict = result as? [String: Any],
                  let items = dict["agents"] as? [[String: Any]] else { return }

            let agents = items.compactMap { AgentSession.parseAgent($0) }

            for agent in agents {
                // Strict filtering: only foreground, user-created agents
                let statusLower = agent.status.lowercased()
                guard !agent.isBackground,
                      agent.createdByAgentId == nil,
                      statusLower != "completed" && statusLower != "failed" && statusLower != "error",
                      !banishedIds.contains(agent.id),
                      !removedIds.contains(agent.id) else { continue }

                if let idx = queue.firstIndex(where: { $0.id == agent.id }) {
                    // Only update if agent data actually changed (avoid unnecessary @Published mutations)
                    let updated = CoverflowAgent(
                        id: agent.id,
                        agent: agent,
                        workspaceId: workspace.id,
                        repositoryName: workspace.repositoryName ?? "unknown",
                        repositoryOwner: workspace.repositoryOwner,
                        workspaceTitle: workspace.title
                    )
                    if queue[idx] != updated {
                        queue[idx] = updated
                    }
                } else {
                    // New agent — add to front
                    let coverflowAgent = CoverflowAgent(
                        id: agent.id,
                        agent: agent,
                        workspaceId: workspace.id,
                        repositoryName: workspace.repositoryName ?? "unknown",
                        repositoryOwner: workspace.repositoryOwner,
                        workspaceTitle: workspace.title
                    )
                    queue.append(coverflowAgent)
                }

                // Seed streaming status from agent state
                if statusLower == "responding" || statusLower == "streaming" || statusLower == "processing"
                    || agent.isStreaming || agent.isResponding || agent.isProcessing {
                    streamingAgentIds.insert(agent.id)
                }

            }
            resortQueue()
        } catch {
            print("[CoverflowStore] Failed to fetch agents for workspace \(workspaceId): \(error)")
        }
    }

    // MARK: - Queue sorting

    /// Re-sort the queue by last activity (most recent first).
    /// The focused card stays focused — only the order changes.
    private func resortQueue() {
        let focusedId = focusedAgentId
        queue.sort { a, b in
            let aStreaming = streamingAgentIds.contains(a.id)
            let bStreaming = streamingAgentIds.contains(b.id)
            let aWaiting = waitingAgentIds.contains(a.id)
            let bWaiting = waitingAgentIds.contains(b.id)
            let aActive = aStreaming || aWaiting
            let bActive = bStreaming || bWaiting
            // Active (streaming or waiting) agents first
            if aActive != bActive { return aActive }
            // Then by most recent timestamp
            let dateA = a.bestTimestamp ?? .distantPast
            let dateB = b.bestTimestamp ?? .distantPast
            return dateA > dateB
        }
        // Restore focused card (TabView selection may shift after sort)
        if let focusedId = focusedId {
            focusedAgentId = focusedId
        }
    }
}
