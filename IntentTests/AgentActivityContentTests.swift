import Foundation
@testable import Intent
import Testing

@MainActor
struct AgentActivityContentTests {
    private let connection = UUID()
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func entry(
        _ id: String,
        running: Bool,
        agent: (id: String, name: String)? = nil
    ) throws -> AgentActivityContent.Entry {
        var dictionary: [String: Any] = [
            "id": id,
            "title": "Workspace \(id)",
            "activity": running ? "agent_running" : "idle",
            "displayStatus": running ? "in_progress" : "complete",
            "statusMessage": "Status \(id)"
        ]
        if let agent {
            let summary: [String: Any] = [
                "id": agent.id, "name": agent.name, "status": "active",
                "isStreaming": running, "isResponding": false
            ]
            dictionary["agentSummary"] = ["agents": [summary]]
        }
        let workspace = try #require(WorkspaceStore.parseWorkspace(dictionary))
        return AgentActivityContent.Entry(connectionId: connection, workspace: workspace)
    }

    @Test func listsOnlyRunningWorkspaces() throws {
        let result = AgentActivityContent.make(from: [
            try entry("done", running: false),
            try entry("live", running: true, agent: ("agent-1", "Coder"))
        ], now: now)
        #expect(result.state.rows.map(\.workspaceId) == ["live"])
        #expect(result.state.runningCount == 1)
        #expect(result.runningKeys == ["\(connection.uuidString)/live"])
        #expect(result.state.rows.first?.link?.agentId == "agent-1")
    }

    @Test func nothingRunningIsEmpty() throws {
        let result = AgentActivityContent.make(from: [try entry("a", running: false)], now: now)
        #expect(result.state.rows.isEmpty)
        #expect(result.state.runningCount == 0)
        #expect(result.runningKeys.isEmpty)
    }

    @Test func capsRowsButCountsEveryRunningWorkspace() throws {
        let entries = try (1...5).map { try entry("w\($0)", running: true) }
        let result = AgentActivityContent.make(from: entries, now: now)
        #expect(result.state.rows.map(\.workspaceId) == ["w1", "w2", "w3"])
        #expect(result.state.runningCount == 5)
        #expect(result.runningKeys.count == 5)
    }

    @Test func linkRoundTripsAndRejectsIncompleteURLs() throws {
        let link = AgentActivityLink(connectionId: connection, workspaceId: "w 1", agentId: "agent-1", agentName: "Fix bug")
        let url = try #require(link.url)
        #expect(AgentActivityLink(url: url) == link)

        let missingAgent = try #require(URL(string: "intent://agent?connection=\(connection.uuidString)&workspace=w"))
        #expect(AgentActivityLink(url: missingAgent) == nil)
        let pairing = try #require(URL(string: "intent://pair?agent=a&workspace=w&connection=\(connection.uuidString)"))
        #expect(AgentActivityLink(url: pairing) == nil)
    }
}
