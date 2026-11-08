import Foundation
@testable import Intent
import Testing

@MainActor
struct AgentActivityTrackerTests {
    private let connection = UUID()
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func entry(
        _ id: String,
        running: Bool = false,
        displayStatus: String? = nil,
        attention: String? = nil,
        agent: (id: String, name: String)? = nil
    ) throws -> AgentActivityTracker.Entry {
        var dictionary: [String: Any] = [
            "id": id,
            "title": "Workspace \(id)",
            "activity": running ? "agent_running" : "idle",
            "statusMessage": "Status \(id)"
        ]
        if let displayStatus { dictionary["displayStatus"] = displayStatus }
        if let attention { dictionary["attention"] = attention }
        if let agent {
            dictionary["agentSummary"] = ["agents": [[
                "id": agent.id, "name": agent.name, "status": "active",
                "isStreaming": running, "isResponding": false
            ]]]
        }
        let workspace = try #require(WorkspaceStore.parseWorkspace(dictionary))
        return AgentActivityTracker.Entry(connectionId: connection, workspace: workspace)
    }

    @Test func showsOnlyWorkspacesSeenRunning() throws {
        var tracker = AgentActivityTracker()
        let state = tracker.content(for: [
            try entry("old", displayStatus: "needs_attention"),
            try entry("live", running: true)
        ], now: start)
        #expect(state.rows.map(\.workspaceId) == ["live"])
        #expect(state.runningCount == 1)
        #expect(state.needsYouCount == 0)
        #expect(tracker.runningKeys == ["\(connection.uuidString)/live"])
    }

    @Test func stoppedWorkspaceSettlesThenExpires() throws {
        var tracker = AgentActivityTracker()
        _ = tracker.content(for: [try entry("a", running: true, agent: ("agent-1", "Coder"))], now: start)

        let done = tracker.content(for: [try entry("a")], now: start.addingTimeInterval(60))
        let row = try #require(done.rows.first)
        #expect(row.phase == .done)
        #expect(row.link?.agentId == "agent-1")
        #expect(row.link?.agentName == "Coder")
        #expect(done.runningCount == 0)

        let failed = tracker.content(for: [try entry("a", displayStatus: "failed")], now: start.addingTimeInterval(120))
        #expect(failed.rows.first?.phase == .failed)

        let expired = tracker.content(
            for: [try entry("a")],
            now: start.addingTimeInterval(60 + AgentActivityTracker.settledRetention + 1)
        )
        #expect(expired.rows.isEmpty)
    }

    @Test func needsYouOutranksRunningAndPersists() throws {
        var tracker = AgentActivityTracker()
        _ = tracker.content(for: [try entry("a", running: true), try entry("b", running: true)], now: start)
        let later = start.addingTimeInterval(AgentActivityTracker.settledRetention * 4)
        let state = tracker.content(for: [
            try entry("a", running: true),
            try entry("b", attention: "review_required")
        ], now: later)
        #expect(state.rows.map(\.workspaceId) == ["b", "a"])
        #expect(state.rows.map(\.phase) == [.needsYou, .running])
        #expect(state.needsYouCount == 1)
        #expect(state.runningCount == 1)
    }

    @Test func capsRowsButCountsEveryWorkspace() throws {
        var tracker = AgentActivityTracker()
        let entries = try (1...5).map { try entry("w\($0)", running: true) }
        let state = tracker.content(for: entries, now: start)
        #expect(state.rows.count == AgentActivityTracker.maxRows)
        #expect(state.rows.map(\.workspaceId) == ["w1", "w2", "w3"])
        #expect(state.runningCount == 5)
    }

    @Test func removedWorkspaceIsForgotten() throws {
        var tracker = AgentActivityTracker()
        _ = tracker.content(for: [try entry("a", running: true)], now: start)
        _ = tracker.content(for: [], now: start)
        let state = tracker.content(for: [try entry("a")], now: start)
        #expect(state.rows.isEmpty)
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
