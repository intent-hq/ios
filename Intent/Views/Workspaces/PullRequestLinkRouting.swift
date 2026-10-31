import SwiftUI

extension View {
    /// Opens links to pull requests a workspace tracks in the pull request
    /// page, pushed on a stack or as a sheet; other links keep their handler.
    func pullRequestLinkRouting(asSheet: Bool = false) -> some View {
        modifier(PullRequestLinkRouting(asSheet: asSheet))
    }
}

private struct PullRequestLinkRouting: ViewModifier {
    let asSheet: Bool
    @Environment(BackendSession.self) private var session
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openURL) private var inheritedOpenURL
    @State private var pushed: PullRequestListItem?
    @State private var presented: PullRequestListItem?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction(handler: open))
            .navigationDestination(item: $pushed) { detail($0, isModal: false) }
            .sheet(item: $presented) { item in
                NavigationStack { detail(item, isModal: true) }
            }
    }

    private func open(_ url: URL) -> OpenURLAction.Result {
        guard let tracked = PullRequestListItem.tracked(url: url, in: session.workspaceStore.workspaces) else {
            inheritedOpenURL(url)
            return .handled
        }
        if asSheet {
            presented = tracked.item
        } else {
            pushed = tracked.item
        }
        return .handled
    }

    private func detail(_ item: PullRequestListItem, isModal: Bool) -> some View {
        PullRequestDetailView(
            item: item,
            connection: session.connection,
            linkedWorkspace: PullRequestListItem.linkedWorkspaces(session.workspaceStore.workspaces)[item.id],
            isModal: isModal
        ) { workspaceId in
            pushed = nil
            presented = nil
            coordinator.onSelectWorkspace(workspaceId)
        }
    }
}
