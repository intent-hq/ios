import SwiftUI

struct WorkspaceSwipeRow: View {
    let workspace: Workspace
    let showRepo: Bool
    let isUpdating: Bool
    @Binding var revealedWorkspaceId: String?
    let onSelect: () -> Void
    let onAction: (WorkspaceAction) -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var isRevealed: Bool { revealedWorkspaceId == workspace.id }
    private var revealBinding: Binding<Bool> {
        Binding(
            get: { isRevealed },
            set: { revealed in
                if revealed {
                    revealedWorkspaceId = workspace.id
                } else if isRevealed {
                    revealedWorkspaceId = nil
                }
            }
        )
    }

    var body: some View {
        WorkspaceSwipeContainer(isRevealed: revealBinding, actionCount: 2, onSwipeBegan: beginSwipe) {
            workspaceButton
                .background(Constants.WorkspaceList.canvas(for: colorScheme))
        } actions: {
            actionButton(.archive, color: .orange)
            actionButton(.delete, color: .red)
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func beginSwipe() {
        if !isRevealed { revealedWorkspaceId = nil }
    }

    private var workspaceButton: some View {
        Button {
            if revealedWorkspaceId != nil {
                revealedWorkspaceId = nil
            } else {
                onSelect()
            }
        } label: {
            WorkspaceRowView(workspace: workspace, colorScheme: colorScheme, showRepo: showRepo, spacious: true)
                .overlay(alignment: .trailing) {
                    if isUpdating { ProgressView().padding(.trailing) }
                }
        }
        .buttonStyle(.plain)
        .disabled(isUpdating)
        .accessibilityIdentifier("workspace.row.\(workspace.id)")
        .contextMenu { menuActions }
        .accessibilityActions { menuActions }
    }

    private func actionButton(_ action: WorkspaceAction, color: Color) -> some View {
        Button(action.label) { select(action) }
            .buttonStyle(WorkspaceSwipeButtonStyle(color: color))
            .disabled(isUpdating)
            .accessibilityLabel("\(action.label) workspace")
            .accessibilityIdentifier("workspace.\(action.rawValue).\(workspace.id)")
    }

    private var menuActions: some View {
        Group {
            Button("Archive workspace", systemImage: "archivebox") { select(.archive) }
            Button("Delete workspace", systemImage: "trash", role: .destructive) { select(.delete) }
        }
        .disabled(isUpdating)
    }

    private func select(_ action: WorkspaceAction) {
        revealedWorkspaceId = nil
        onAction(action)
    }
}
