import SwiftUI

extension View {
    /// Opens links to pull requests a workspace tracks in the pull request
    /// page, pushed on the stack or in the iPad main pane; other links keep their handler.
    func pullRequestLinkRouting(inIPadDetail: Bool = false) -> some View {
        modifier(PullRequestLinkRouting(inIPadDetail: inIPadDetail))
    }
}

extension EnvironmentValues {
    /// Opens a pull request page the way tracked links do; nil outside link routing.
    @Entry var openPullRequest: ((PullRequestListItem) -> Void)?
}

private struct PullRequestLinkRouting: ViewModifier {
    let inIPadDetail: Bool
    @Environment(BackendSession.self) private var session
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openURL) private var inheritedOpenURL
    @State private var pushed: PullRequestListItem?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction(handler: open))
            .environment(\.openPullRequest, show)
            .navigationDestination(item: $pushed) { detail($0) }
    }

    private func open(_ url: URL) -> OpenURLAction.Result {
        guard let tracked = PullRequestListItem.tracked(url: url, in: session.workspaceStore.workspaces) else {
            inheritedOpenURL(url)
            return .handled
        }
        show(tracked.item)
        return .handled
    }

    private func show(_ item: PullRequestListItem) {
        if inIPadDetail {
            coordinator.onSelectIPadPullRequest(item)
        } else {
            pushed = item
        }
    }

    private func detail(_ item: PullRequestListItem) -> some View {
        PullRequestDetailView(
            item: item,
            connection: session.connection,
            linkedWorkspace: PullRequestListItem.linkedWorkspaces(session.workspaceStore.workspaces)[item.id]
        ) { workspaceId in
            pushed = nil
            coordinator.onSelectWorkspace(workspaceId)
        }
    }
}
