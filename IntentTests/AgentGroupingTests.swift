import Foundation
@testable import Intent
import Testing

@MainActor
struct AgentGroupingTests {
    private func row(_ id: String, parent: Any? = nil, creator: String? = nil, background: Bool = false) throws -> AgentSession {
        var wire: [String: Any] = ["id": id, "name": id, "metadata": ["isBackground": background]]
        if let parent { wire["parentAgentId"] = parent }
        if let creator { wire["metadata"] = ["createdByAgentId": creator, "isBackground": background] }
        return try #require(AgentSession.parseAgent(wire))
    }

    @Test func canonicalParentWinsAndEmptyOrNullParentUsesLegacyCreator() throws {
        let model = AgentListViewModel()
        model.agents = try [
            row("parent"), row("canonical", parent: "parent", creator: "wrong"),
            row("legacy", creator: "parent"), row("empty", parent: "", creator: "parent"), row("null", parent: NSNull(), creator: "parent")
        ]
        #expect(Set(model.delegatedAgents(for: "parent").map(\.id)) == ["canonical", "legacy", "empty", "null"])
        #expect(model.delegatedAgents(for: "wrong").isEmpty)
        #expect(model.foregroundAgents.map(\.id) == ["parent"])
    }

    @Test func partialCacheNeverInventsOrphansOrBackgroundRoots() throws {
        let state = AgentListState()
        state.scopeCounts = AgentScopeCounts(wire: ["topLevel": 0, "background": 1, "delegated": 3])
        state.delegatedCounts = AgentDelegatedCounts(wire: [
            "running": 0, "byParent": [:], "orphaned": ["total": 1, "running": 0]
        ])
        let model = AgentListViewModel(list: state)
        model.agents = try [
            row("child", parent: "unloaded-background", background: true), row("orphan", parent: "retired")
        ]
        #expect(model.foregroundAgents.isEmpty)
        #expect(model.standaloneBackgroundAgents.isEmpty)
        #expect(model.orphanedAgents.isEmpty)
        state.orphanedAgentIds = ["orphan"]
        #expect(model.orphanedAgents.map(\.id) == ["orphan"])
    }

    @Test func collapsedCountsNeedNoRowsAndZeroIsSupported() {
        let state = AgentListState()
        state.scopeCounts = AgentScopeCounts(wire: ["topLevel": 1, "background": 2, "delegated": 3])
        state.delegatedCounts = AgentDelegatedCounts(wire: [
            "running": 1, "byParent": ["parent": ["total": 3, "running": 1]], "orphaned": ["total": 0, "running": 0]
        ])
        state.retiredCount = 4
        let model = AgentListViewModel(list: state)
        #expect(model.count(for: .delegated(parentId: "parent")) == 3)
        #expect(model.runningCount(for: .delegated(parentId: "parent")) == 1)
        #expect(model.count(for: .background) == 2)
        #expect(model.count(for: .orphaned) == 0)
        #expect(model.count(for: .retired) == 4)
        #expect(model.hasAgentSections)
    }

    @Test func nestedGroupsRemainWithBackgroundAndOrphanParents() throws {
        let state = AgentListState()
        state.scopeCounts = AgentScopeCounts(wire: ["topLevel": 0, "background": 1, "delegated": 4])
        state.delegatedCounts = AgentDelegatedCounts(wire: ["running": 0, "byParent": [:], "orphaned": ["total": 1, "running": 0]])
        state.orphanedAgentIds = ["orphan"]
        let model = AgentListViewModel(list: state)
        model.agents = try [
            row("background", background: true), row("child", parent: "background", background: true),
            row("grandchild", parent: "child"), row("orphan", parent: "deleted"), row("orphan-child", parent: "orphan")
        ]
        model.expandedGroups = [.delegated(parentId: "background"), .delegated(parentId: "child"), .delegated(parentId: "orphan")]
        #expect(model.visibleTree(model.standaloneBackgroundAgents).map(\.agent.id) == ["background", "child", "grandchild"])
        #expect(model.visibleTree(model.orphanedAgents).map(\.agent.id) == ["orphan", "orphan-child"])
        model.expandedGroups = []
        #expect(model.visibleTree(model.standaloneBackgroundAgents).map(\.agent.id) == ["background"])
    }

    @Test func legacyWholeDelegatedBinRevealsNestedRowsWithoutFetchingBackgroundParents() throws {
        let state = AgentListState()
        state.scopeCounts = AgentScopeCounts(wire: ["topLevel": 1, "background": 1, "delegated": 3])
        let model = AgentListViewModel(list: state)
        model.agents = try [
            row("parent"), row("child", parent: "parent"), row("grandchild", parent: "child"),
            row("background-child", parent: "unloaded-background")
        ]
        model.expandedGroups = [.orphaned]
        #expect(model.visibleTree(model.foregroundAgents).map(\.agent.id) == ["parent", "child", "grandchild"])
        #expect(model.orphanedAgents.map(\.id) == ["background-child"])
    }
    @Test func scopeAwareFixtureCountsDoNotDependOnRequestedRows() throws {
        let rows = DemoAgentListFixtures.groupRows
        let top = DemoAgentListFixtures.response(rows: rows, params: ["scope": "topLevel"])
        let orphaned = DemoAgentListFixtures.response(rows: rows, params: ["scope": "delegated", "orphanedOnly": true])
        let child = DemoAgentListFixtures.response(rows: rows, params: ["scope": "delegated", "parentAgentId": "groups-background"])
        let retired = DemoAgentListFixtures.response(rows: rows, params: ["retiredOnly": true])
        #expect((top["agents"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["groups-parent"])
        #expect((child["agents"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["groups-background-child"])
        #expect((retired["agents"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == ["groups-retired"])
        #expect((orphaned["agents"] as? [[String: Any]])?.count == 2)
        #expect(AgentScopeCounts(wire: try #require(top["scopeCounts"] as? [String: Any]))
            == AgentScopeCounts(wire: try #require(child["scopeCounts"] as? [String: Any])))
    }

    @Test func retiredRowsCannotBecomeActiveRootsAndResetCollapsesEverything() throws {
        let model = AgentListViewModel()
        var retired = try row("retired")
        retired.retiredAt = "2026-09-30T00:00:00Z"
        model.agents = try [row("parent"), row("orphan", parent: "retired"), retired]
        #expect(model.foregroundAgents.map(\.id) == ["orphan", "parent"])
        model.expandedGroups = [.background, .orphaned, .retired, .delegated(parentId: "parent")]
        model.reset()
        #expect(model.agents.isEmpty)
        #expect(model.expandedGroups.isEmpty)
    }
}
