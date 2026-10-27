@testable import Intent
import Testing

struct WorkspaceSidebarStateTests {
    private static let conversation = AppScreen.agentConversation(agentId: "agent", workspaceId: "ws", agentName: "Agent")
    private static let note = AppScreen.noteDetail(noteId: "note", workspaceId: "ws", noteTitle: "Spec")

    private static func route(_ screen: AppScreen, request: Int = 1) -> WorkspaceSidebarState.Route {
        WorkspaceSidebarState.Route(screen: String(describing: screen), requestId: request)
    }

    @Test func workspaceSubPagesMoveTheWorkspaceIntoThePersistentSidebar() {
        let state = WorkspaceSidebarState()
        for screen in [Self.conversation, Self.note] {
            #expect(state.content(for: screen, route: Self.route(screen), isPersistent: true) == .workspace(id: "ws"))
            #expect(state.content(for: screen, route: Self.route(screen), isPersistent: false) == .workspaceList)
        }
    }

    @Test func listAndOverviewKeepTheList() {
        for screen in [AppScreen.workspaceList, .workspaceDetail(workspaceId: "ws")] {
            #expect(WorkspaceSidebarState().content(for: screen, route: Self.route(screen), isPersistent: true) == .workspaceList)
        }
    }

    @Test func assistantConversationsKeepTheList() {
        let screen = AppScreen.agentConversation(agentId: "a", workspaceId: Workspace.chiefWorkspaceId, agentName: "Assistant")
        #expect(WorkspaceSidebarState().content(for: screen, route: Self.route(screen), isPersistent: true) == .workspaceList)
    }

    @Test func backShowsTheListUntilTheNextSelection() {
        var state = WorkspaceSidebarState()
        state.showList(for: Self.route(Self.conversation))
        #expect(state.content(for: Self.conversation, route: Self.route(Self.conversation), isPersistent: true) == .workspaceList)
        // Reselecting the same agent is a new request; a different page is a new screen.
        #expect(state.content(for: Self.conversation, route: Self.route(Self.conversation, request: 2), isPersistent: true)
            == .workspace(id: "ws"))
        #expect(state.content(for: Self.note, route: Self.route(Self.note), isPersistent: true) == .workspace(id: "ws"))
    }
}
