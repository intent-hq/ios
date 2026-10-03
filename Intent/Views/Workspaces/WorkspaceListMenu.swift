import SwiftUI

struct WorkspaceListMenu: View {
    @Binding var showArchived: Bool
    let onRecentAgents: () -> Void
    let onRecentWorkspaces: () -> Void

    var body: some View {
        Menu {
            Button(action: onRecentAgents) {
                Label {
                    Text("Recent agents").interFont(Constants.Typography.bodyS)
                } icon: {
                    Image(systemName: "bubble.left.and.bubble.right")
                }
            }
            .accessibilityIdentifier("workspaces.menu.recentAgents")
            Button(action: onRecentWorkspaces) {
                Label {
                    Text("Recent workspaces").interFont(Constants.Typography.bodyS)
                } icon: {
                    Image(systemName: "clock")
                }
            }
            .accessibilityIdentifier("workspaces.menu.recentWorkspaces")
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
        .accessibilityLabel("Workspace list options")
        .accessibilityIdentifier("workspaces.menu")
    }
}
