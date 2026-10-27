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
}
