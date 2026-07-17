import Foundation
import Combine

@MainActor
class WorkspaceStore: ObservableObject {
    static let shared = WorkspaceStore()

    @Published var workspaces: [Workspace] = []
    @Published var lastUpdated: Date?
    @Published var isLoading = false

    private var connectionObserver: AnyCancellable?
    private var eventHandlerId: UUID?

    /// Tracks the highest-known lastActivity per workspace so optimistic
    /// event-driven timestamps are never overwritten by stale server data.
    var lastActivityHighWaterMark: [String: String] = [:]

    private init() {
        observeConnection()
    }

    /// Test-only initializer that skips connection observation
    init(forTesting: Bool) {
        // No connection observation for unit tests
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
        await fetchAll()
        await subscribeToEvents()
    }

    // MARK: - Fetch

    func fetchAll() async {
        await _fetchAll()
    }

    private func _fetchAll() async {
        isLoading = true
        do {
            let result = try await ConnectionManager.shared.request("workspace.list")
            var parsed = Self.parseWorkspaces(from: result)
            applyHighWaterMarks(to: &parsed)
            workspaces = parsed
            lastUpdated = Date()
        } catch {
            print("[WorkspaceStore] Failed to fetch workspaces: \(error)")
        }
        isLoading = false
    }

    /// Merges high-water-mark timestamps into the given workspaces array so
    /// optimistic event-driven timestamps are never overwritten by stale server data.
    func applyHighWaterMarks(to workspaces: inout [Workspace]) {
        for i in workspaces.indices {
            let ws = workspaces[i]
            if let hwm = lastActivityHighWaterMark[ws.id],
               let serverTs = ws.lastActivity,
               hwm > serverTs {
                workspaces[i] = Workspace(
                    id: ws.id,
                    title: ws.title,
                    branch: ws.branch,
                    baseRef: ws.baseRef,
                    status: ws.status,
                    activity: ws.activity,
                    lastActivity: hwm,
                    updatedAt: ws.updatedAt,
                    repositoryOwner: ws.repositoryOwner,
                    repositoryName: ws.repositoryName,
                    prStatus: ws.prStatus,
                    prNumber: ws.prNumber,
                    diffSummaryTotalFiles: ws.diffSummaryTotalFiles,
                    taskStatsTotal: ws.taskStatsTotal,
                    taskStatsCompleted: ws.taskStatsCompleted,
                    taskStatsInProgress: ws.taskStatsInProgress,
                    agentSummaryCount: ws.agentSummaryCount,
                    agentSummaryAgents: ws.agentSummaryAgents
                )
            }
        }
    }

    // MARK: - Event subscription

    private func subscribeToEvents() async {
        // Remove old handler to prevent accumulation on reconnect
        if let handlerId = eventHandlerId {
            ConnectionManager.shared.removeEventHandler(id: handlerId)
        }

        // Register event handler on ConnectionManager
        // (server subscription is handled centrally by ConnectionManager.subscribeToAllEvents)
        eventHandlerId = ConnectionManager.shared.onEvent { [weak self] method, params in
            Task { @MainActor in
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

        print("[WorkspaceStore] Received event: \(eventType)")

        let eventTimestamp = event["timestamp"] as? String ?? ISO8601DateFormatter().string(from: Date())
        let eventWorkspaceId = event["workspaceId"] as? String

        switch eventType {
        case "agent:idle", "agent:started", "agent:status-changed":
            // Update lastActivity locally for immediate UI feedback
            if let wsId = eventWorkspaceId {
                updateLocalLastActivity(workspaceId: wsId, timestamp: eventTimestamp)
            }
            // Also re-fetch to get updated agentSummary
            Task { await fetchAll() }

        case let t where t.hasPrefix("workspace:"):
            // Check for workspace:updated with lastActivity changes
            if eventType == "workspace:updated",
               let data = event["data"] as? [String: Any],
               let changes = data["changes"] as? [String: Any],
               let lastActivity = changes["lastActivity"] as? String,
               let wsId = eventWorkspaceId {
                updateLocalLastActivity(workspaceId: wsId, timestamp: lastActivity)
            }
            // Refetch on events that change workspace list or visible state
            if eventType == "workspace:activity-changed" ||
               eventType == "workspace:updated" ||
               eventType == "workspace:archived" ||
               eventType == "workspace:deleted" {
                Task { await fetchAll() }
            }

        case let t where t.hasPrefix("agent:"):
            // Handled by specific cases above (agent:idle, agent:started, agent:status-changed)
            break

        default:
            break
        }
    }

    func updateLocalLastActivity(workspaceId: String, timestamp: String) {
        // Update high-water mark — only store if newer than existing entry
        if let existing = lastActivityHighWaterMark[workspaceId] {
            if timestamp > existing {
                lastActivityHighWaterMark[workspaceId] = timestamp
            }
        } else {
            lastActivityHighWaterMark[workspaceId] = timestamp
        }

        let effectiveTimestamp = lastActivityHighWaterMark[workspaceId] ?? timestamp

        if let index = workspaces.firstIndex(where: { $0.id == workspaceId }) {
            let ws = workspaces[index]
            workspaces[index] = Workspace(
                id: ws.id,
                title: ws.title,
                branch: ws.branch,
                baseRef: ws.baseRef,
                status: ws.status,
                activity: ws.activity,
                lastActivity: effectiveTimestamp,
                updatedAt: ws.updatedAt,
                repositoryOwner: ws.repositoryOwner,
                repositoryName: ws.repositoryName,
                prStatus: ws.prStatus,
                prNumber: ws.prNumber,
                diffSummaryTotalFiles: ws.diffSummaryTotalFiles,
                taskStatsTotal: ws.taskStatsTotal,
                taskStatsCompleted: ws.taskStatsCompleted,
                taskStatsInProgress: ws.taskStatsInProgress,
                agentSummaryCount: ws.agentSummaryCount,
                agentSummaryAgents: ws.agentSummaryAgents
            )
        }
    }

    // MARK: - Parsing

    static func parseWorkspaces(from result: Any) -> [Workspace] {
        guard let dict = result as? [String: Any],
              let items = dict["workspaces"] as? [[String: Any]] else {
            guard let items = result as? [[String: Any]] else { return [] }
            return items.compactMap { parseWorkspace($0) }
        }
        return items.compactMap { parseWorkspace($0) }
    }

    static func parseWorkspace(_ dict: [String: Any]) -> Workspace? {
        guard let id = dict["id"] as? String,
              let title = dict["title"] as? String else { return nil }

        let diffSummary = dict["diffSummary"] as? [String: Any]
        let taskStats = dict["taskStats"] as? [String: Any]
        let agentSummary = dict["agentSummary"] as? [String: Any]

        // DEBUG: Log agent summary data
        print("[WorkspaceStore] Parsing workspace '\(title)': agentSummary=\(agentSummary != nil ? "present" : "nil"), count=\(agentSummary?["count"] ?? "nil"), agents=\((agentSummary?["agents"] as? [[String: Any]])?.count ?? 0)")
        if let agents = agentSummary?["agents"] as? [[String: Any]] {
            for agent in agents {
                print("[WorkspaceStore]   Agent: id=\(agent["id"] ?? "?"), name=\(agent["name"] ?? "?"), status=\(agent["status"] ?? "?")")
            }
        }
        // END DEBUG

        var agentInfos: [WorkspaceAgentInfo]?
        if let agents = agentSummary?["agents"] as? [[String: Any]] {
            agentInfos = agents.compactMap { agentDict -> WorkspaceAgentInfo? in
                guard let agentId = agentDict["id"] as? String,
                      let name = agentDict["name"] as? String,
                      let status = agentDict["status"] as? String else { return nil }
                return WorkspaceAgentInfo(
                    id: agentId,
                    name: name,
                    status: status,
                    specialist: agentDict["specialist"] as? String,
                    lastActivity: agentDict["lastActivity"] as? String,
                    isStreaming: agentDict["isStreaming"] as? Bool ?? false,
                    isResponding: agentDict["isResponding"] as? Bool ?? false
                )
            }
        }

        return Workspace(
            id: id,
            title: title,
            branch: dict["branch"] as? String,
            baseRef: dict["baseRef"] as? String,
            status: dict["status"] as? String,
            activity: dict["activity"] as? String,
            lastActivity: dict["lastActivity"] as? String,
            updatedAt: dict["updatedAt"] as? String,
            repositoryOwner: dict["repositoryOwner"] as? String,
            repositoryName: dict["repositoryName"] as? String ?? dict["repo"] as? String,
            prStatus: dict["prStatus"] as? String,
            prNumber: dict["prNumber"] as? Int,
            diffSummaryTotalFiles: diffSummary?["totalFiles"] as? Int,
            taskStatsTotal: taskStats?["total"] as? Int,
            taskStatsCompleted: taskStats?["completed"] as? Int,
            taskStatsInProgress: taskStats?["inProgress"] as? Int,
            agentSummaryCount: agentSummary?["count"] as? Int,
            agentSummaryAgents: agentInfos
        )
    }
}

