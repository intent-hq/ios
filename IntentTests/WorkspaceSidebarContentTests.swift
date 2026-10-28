@testable import Intent
import Testing

struct WorkspaceSidebarContentTests {
    @Test func workspaceSubPagesMoveTheWorkspaceIntoThePersistentSidebar() {
        let screens = [
            AppScreen.agentConversation(agentId: "agent", workspaceId: "ws", agentName: "Agent"),
            .noteDetail(noteId: "note", workspaceId: "ws", noteTitle: "Spec")
        ]
        for screen in screens {
            #expect(WorkspaceSidebarContent.resolve(screen: screen, isPersistent: true) == .workspace(id: "ws"))
            #expect(WorkspaceSidebarContent.resolve(screen: screen, isPersistent: false) == .workspaceList)
        }
    }

    @Test func listAndOverviewKeepTheList() {
        for screen in [AppScreen.workspaceList, .workspaceDetail(workspaceId: "ws")] {
            #expect(WorkspaceSidebarContent.resolve(screen: screen, isPersistent: true) == .workspaceList)
        }
    }

    @Test func assistantConversationsKeepTheList() {
        let screen = AppScreen.agentConversation(agentId: "a", workspaceId: Workspace.chiefWorkspaceId, agentName: "Assistant")
        #expect(WorkspaceSidebarContent.resolve(screen: screen, isPersistent: true) == .workspaceList)
    }

    @Test func revealOpensEveryKnownAncestorAndTheBackgroundRoot() throws {
        let rows = try [
            agent("root", background: true),
            agent("lead", parent: "root"),
            agent("worker", parent: "lead")
        ]
        let lookup = { (id: String) in rows.first { $0.id == id } }
        let worker = try #require(lookup("worker"))
        let groups = WorkspaceSidebarAgents.revealGroups(for: worker, lookup: lookup)
        #expect(groups == [.delegated(parentId: "lead"), .delegated(parentId: "root"), .background])
    }

    @Test func revealStopsAtUnknownParentsCyclesAndForegroundRoots() throws {
        let unknown = try agent("child", parent: "missing")
        #expect(WorkspaceSidebarAgents.revealGroups(for: unknown) { _ in nil } == [.delegated(parentId: "missing")])

        let cycle = try [agent("first", parent: "second"), agent("second", parent: "first")]
        let groups = WorkspaceSidebarAgents.revealGroups(for: cycle[0]) { id in cycle.first { $0.id == id } }
        #expect(groups == [.delegated(parentId: "second"), .delegated(parentId: "first")])

        #expect(try WorkspaceSidebarAgents.revealGroups(for: agent("top")) { _ in nil }.isEmpty)
    }

    @Test func retiredAgentsAreRevealedInTheRetiredSection() throws {
        let retired = try agent("old", parent: "lead", retired: true)
        #expect(WorkspaceSidebarAgents.revealGroups(for: retired) { _ in nil } == [.retired])
    }

    private func agent(_ id: String, parent: String? = nil, background: Bool = false, retired: Bool = false) throws -> AgentSession {
        var row: [String: Any] = ["id": id, "name": id, "metadata": ["isBackground": background]]
        row["parentAgentId"] = parent
        row["retiredAt"] = retired ? "2026-10-01T00:00:00Z" : nil
        return try #require(AgentSession.parseAgent(row))
    }
}
