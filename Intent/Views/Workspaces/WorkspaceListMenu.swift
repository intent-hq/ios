import SwiftUI

struct WorkspaceListMenu: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Binding var showArchived: Bool
    let onCreateWorkspace: () -> Void
    let onRecentAgents: () -> Void
    let onRecentConnections: () -> Void

    var body: some View {
        Menu {
            newWorkspaceAction
            Divider()
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
        } label: {
            ToolbarOverflowLabel()
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
        .disabled(!coordinator.canCreateWorkspace)
        .accessibilityIdentifier("workspaces.menu.create")
    }
}
