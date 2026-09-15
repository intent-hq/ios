import Foundation

private struct WorkspaceParsingContext {
    let dictionary: [String: Any]
    let id: String
    let title: String
    let diffSummary: [String: Any]
    let taskStats: [String: Any]
    let agentSummary: [String: Any]
    let agentSummaryWasReported: Bool
    let agents: [WorkspaceAgentInfo]
    let pullRequests: [WorkspacePullRequest]
    let activePullRequest: WorkspacePullRequest?
}

extension WorkspaceStore {
    static func parseWorkspaces(from result: Any) -> [Workspace] {
        guard let dictionary = result as? [String: Any],
              let items = dictionary["workspaces"] as? [[String: Any]] else {
            guard let items = result as? [[String: Any]] else { return [] }
            return items.compactMap { parseWorkspace($0) }
        }
        return items.compactMap { parseWorkspace($0) }
    }

    static func parseWorkspace(_ dictionary: [String: Any]) -> Workspace? {
        guard let id = dictionary["id"] as? String,
              let title = dictionary["title"] as? String else { return nil }
        let rawAgentSummary = dictionary["agentSummary"] as? [String: Any]
        let agentSummary = rawAgentSummary ?? [:]
        logAgentSummary(title: title, summary: agentSummary, wasReported: rawAgentSummary != nil)
        return workspace(from: WorkspaceParsingContext(
            dictionary: dictionary,
            id: id,
            title: title,
            diffSummary: dictionary["diffSummary"] as? [String: Any] ?? [:],
            taskStats: dictionary["taskStats"] as? [String: Any] ?? [:],
            agentSummary: agentSummary,
            agentSummaryWasReported: rawAgentSummary?["agents"] is [[String: Any]],
            agents: parseAgents(from: agentSummary),
            pullRequests: parsePullRequests(from: dictionary),
            activePullRequest: parseActivePullRequest(from: dictionary)
        ))
    }

    private static func parseAgents(from summary: [String: Any]) -> [WorkspaceAgentInfo] {
        guard let agents = summary["agents"] as? [[String: Any]] else { return [] }
        return agents.compactMap { dictionary in
            guard let id = dictionary["id"] as? String,
                  let name = dictionary["name"] as? String,
                  let status = dictionary["status"] as? String else { return nil }
            return WorkspaceAgentInfo(
                id: id,
                name: name,
                status: status,
                specialist: dictionary["specialist"] as? String,
                lastActivity: dictionary["lastActivity"] as? String,
                isStreaming: dictionary["isStreaming"] as? Bool ?? false,
                isResponding: dictionary["isResponding"] as? Bool ?? false
            )
        }
    }

    private static func parsePullRequests(from dictionary: [String: Any]) -> [WorkspacePullRequest] {
        guard let rawPullRequests = dictionary["pullRequests"] as? [[String: Any]] else { return [] }
        return rawPullRequests.compactMap { WorkspacePullRequest(wire: $0) }
    }

    private static func parseActivePullRequest(from dictionary: [String: Any]) -> WorkspacePullRequest? {
        guard let rawPullRequest = dictionary["activePullRequest"] as? [String: Any] else { return nil }
        return WorkspacePullRequest(wire: rawPullRequest)
    }

    private static func logAgentSummary(
        title: String,
        summary: [String: Any],
        wasReported: Bool
    ) {
        AppLog.workspace.debug(
            "[WorkspaceStore] Parsing workspace '\(title)': agentSummary=\(wasReported ? "present" : "nil"), count=\(summary["count"] ?? "nil"), agents=\((summary["agents"] as? [[String: Any]])?.count ?? 0)"
        )
        guard let agents = summary["agents"] as? [[String: Any]] else { return }
        for agent in agents {
            AppLog.workspace.debug("[WorkspaceStore]   Agent: id=\(agent["id"] ?? "?"), name=\(agent["name"] ?? "?"), status=\(agent["status"] ?? "?")")
        }
    }

    private static func workspace(from context: WorkspaceParsingContext) -> Workspace {
        let dictionary = context.dictionary
        return Workspace(
            id: context.id,
            title: context.title,
            branch: dictionary["branch"] as? String,
            baseRef: dictionary["baseRef"] as? String,
            status: dictionary["status"] as? String,
            activity: dictionary["activity"] as? String,
            displayStatus: dictionary["displayStatus"] as? String,
            attention: dictionary["attention"] as? String,
            waiting: dictionary["waiting"] as? Bool ?? false,
            lastActivity: dictionary["lastActivity"] as? String,
            createdAt: dictionary["createdAt"] as? String,
            updatedAt: dictionary["updatedAt"] as? String,
            repositoryOwner: dictionary["repositoryOwner"] as? String,
            repositoryName: dictionary["repositoryName"] as? String ?? dictionary["repo"] as? String,
            prStatus: dictionary["prStatus"] as? String,
            prNumber: dictionary["prNumber"] as? Int,
            diffSummaryTotalFiles: context.diffSummary["totalFiles"] as? Int,
            taskStatsTotal: context.taskStats["total"] as? Int,
            taskStatsCompleted: context.taskStats["completed"] as? Int,
            taskStatsInProgress: context.taskStats["inProgress"] as? Int,
            agentSummaryCount: context.agentSummary["count"] as? Int,
            agentSummaryAgents: context.agents,
            pullRequests: context.pullRequests,
            agentSummaryWasReported: context.agentSummaryWasReported,
            pullRequestsWereReported: dictionary["pullRequests"] is [[String: Any]],
            activePullRequest: context.activePullRequest
        )
    }
}
