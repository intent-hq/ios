import SwiftUI

/// The iPad rail's Pull requests section: the same list, filters and swipe
/// actions as the iPhone page, with the title opening the list options.
struct IPadPullRequestsSidebar: View {
    let session: BackendSession
    let onCollapse: () -> Void
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("pullRequests.filter") private var filter: PullRequestListStore.Filter = .created
    @AppStorage("pullRequests.groupsByProject") private var groupsByProject = false
    @State private var showsClosed = false
    @State private var detail: PullRequestListItem?
    @State private var creation: PullRequestListItem?

    private var workspaces: [Workspace] { session.workspaceStore.workspaces }

    private var query: PullRequestListStore.Query {
        PullRequestListStore.Query(
            repositories: PullRequestListRepository.scope(workspaces),
            filter: filter,
            showsClosed: showsClosed
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            IPadSidebarHeader(onCollapse: onCollapse) {
                optionsMenu
            } actions: {
                EmptyView()
            }
            WorkspaceSearchBar(
                viewMode: $filter,
                isSearching: .constant(false),
                horizontalPadding: IPadSidebarStyle.inset,
                isSidebar: true,
                identifierPrefix: "pullRequests.filter",
                accessibilityTitle: "Pull request filter"
            )
            ScrollView {
                LazyVStack(spacing: 0) {
                    PullRequestListContent(
                        store: session.pullRequestListStore,
                        query: query,
                        workspaces: workspaces,
                        groupsByProject: groupsByProject
                    ) { workspaceId in
                        openWorkspace(workspaceId)
                    } onOpenDetail: { item in
                        detail = item
                    } onOpenAgent: { workspaceId in
                        coordinator.onSelectIPadSection(.workspaces)
                        coordinator.onOpenRecentWorkspaceAgent(workspaceId)
                    } onCreateWorkspace: { item in
                        if coordinator.canCreateWorkspace { creation = item }
                    }
                }
                .padding(.top, IPadSidebarStyle.compactSectionSpacing)
            }
            .refreshable { await session.pullRequestListStore.load(query) }
        }
        .background(IPadSidebarStyle.background(for: colorScheme))
        .task(id: query) { await PullRequestListContent.sync(session.pullRequestListStore, to: query) }
        .sheet(item: $detail) { item in
            PullRequestDetailView(
                item: item,
                connection: session.connection,
                linkedWorkspace: PullRequestListItem.linkedWorkspaces(workspaces)[item.id]
            ) { workspaceId in
                detail = nil
                openWorkspace(workspaceId)
            }
        }
        .sheet(item: $creation) { item in
            CreateWorkspaceView(session: session, coordinator: coordinator, pullRequest: item)
                .environment(coordinator)
        }
        .accessibilityIdentifier("ipad.pullRequests")
    }

    private var optionsMenu: some View {
        Menu {
            Button {
                groupsByProject.toggle()
            } label: {
                Label(groupsByProject ? "List by recent" : "Group by project", image: groupsByProject ? .list : .folders)
            }
            .accessibilityIdentifier("workspaces.menu.pullRequestGrouping")
            Button {
                showsClosed.toggle()
            } label: {
                Label(showsClosed ? "Hide closed" : "Show closed", image: .pullRequestClosed)
            }
            .accessibilityIdentifier("workspaces.menu.closedPullRequests")
        } label: {
            IPadSidebarTitle(title: "Pull requests")
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel("Pull request list options")
        .accessibilityIdentifier("pullRequests.menu")
    }

    private func openWorkspace(_ workspaceId: String) {
        coordinator.onSelectIPadSection(.workspaces)
        coordinator.onSelectWorkspace(workspaceId)
    }
}
