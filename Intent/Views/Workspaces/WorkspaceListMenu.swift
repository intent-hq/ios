import SwiftUI

/// Which list the workspace page shows; switched from its overflow menu.
nonisolated enum WorkspaceListContentKind: String {
    case pullRequests
    case workspaces
}

struct WorkspaceListMenu: View {
    @Binding var showArchived: Bool
    // Native toolbar hosts must not rely on inherited observable objects (#745).
    let canCreateWorkspace: Bool
    let onCreateWorkspace: () -> Void
    let onRecentAgents: () -> Void
    let onRecentConnections: () -> Void

    var showsSidebarTitle = false
    var content: Binding<WorkspaceListContentKind>?
    var showsClosedPullRequests: Binding<Bool>?

    private var showsPullRequests: Bool { content?.wrappedValue == .pullRequests }

    var body: some View {
        Menu {
            newWorkspaceAction
            Divider()
            if let content {
                contentSwitch(content)
            }
            Button(action: onRecentAgents) {
                Label {
                    Text("Recent agents").interFont(Constants.Typography.bodyS)
                } icon: {
                    Image(.messageList)
                }
            }
            .accessibilityIdentifier("workspaces.menu.recentAgents")
            Button(action: onRecentConnections) {
                Label {
                    Text("Recent connections").interFont(Constants.Typography.bodyS)
                } icon: {
                    Image(.connectionLaptop)
                }
            }
            .accessibilityIdentifier("workspaces.menu.recentConnections")
            if showsPullRequests, let showsClosedPullRequests {
                closedToggle(showsClosedPullRequests)
            } else {
                archivedToggle
            }
        } label: {
            if showsSidebarTitle {
                IPadSidebarTitle(title: "Workspaces")
            } else {
                ToolbarOverflowLabel()
            }
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel("Workspace list options")
        .accessibilityIdentifier("workspaces.menu")
    }

    private var newWorkspaceAction: some View {
        Button(action: onCreateWorkspace) {
            Label {
                Text("New workspace").interFont(Constants.Typography.bodyS)
            } icon: {
                Image(.addIcon)
            }
        }
        .disabled(!canCreateWorkspace)
        .accessibilityIdentifier("workspaces.menu.create")
    }

    private func closedToggle(_ showsClosed: Binding<Bool>) -> some View {
        Button {
            showsClosed.wrappedValue.toggle()
        } label: {
            Label {
                Text(showsClosed.wrappedValue ? "Hide closed" : "Show closed")
                    .interFont(Constants.Typography.bodyS)
            } icon: {
                Image(.pullRequestClosed)
            }
        }
        .accessibilityIdentifier("workspaces.menu.closedPullRequests")
    }

    private var archivedToggle: some View {
        Button {
            showArchived.toggle()
        } label: {
            Label {
                Text(showArchived ? "Hide archived" : "Show archived")
                    .interFont(Constants.Typography.bodyS)
            } icon: {
                Image(.archive)
            }
        }
        .accessibilityIdentifier("workspaces.menu.archived")
    }

    private func contentSwitch(_ content: Binding<WorkspaceListContentKind>) -> some View {
        Button {
            content.wrappedValue = showsPullRequests ? .workspaces : .pullRequests
        } label: {
            Label {
                Text(showsPullRequests ? "Workspaces" : "Pull requests")
                    .interFont(Constants.Typography.bodyS)
            } icon: {
                Image(showsPullRequests ? ImageResource.folders : ImageResource.pullRequestOpen)
            }
        }
        .accessibilityIdentifier("workspaces.menu.content")
    }
}
