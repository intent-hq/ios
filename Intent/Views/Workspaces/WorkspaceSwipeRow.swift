import SwiftUI

struct WorkspaceSwipeRow: View {
    let workspace: Workspace
    let showRepo: Bool
    let isUpdating: Bool
    @Binding var revealedTarget: WorkspaceSwipeTarget?
    @Binding var workspaceSwipeProgress: [String: CGFloat]
    let nextWorkspaceId: String?
    let onSelect: () -> Void
    let onAction: (WorkspaceAction) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dividerOpacity: Double {
        let progress = workspaceSwipeProgress[workspace.id, default: 0]
        let nextProgress = nextWorkspaceId.flatMap { workspaceSwipeProgress[$0] } ?? 0
        return Double(1 - min(1, max(progress, nextProgress) / DividerStyle.fadeProgress))
    }

    var body: some View {
        WorkspaceSwipeContainer(
            target: .workspace(workspace.id),
            revealedTarget: $revealedTarget,
            actionCount: 2,
            horizontalInset: Constants.WorkspaceList.pageInset,
            onSwipeProgressChanged: updateSwipeProgress
        ) { progress in
            workspaceButton(swipeProgress: progress)
        } actions: {
            actionButton(.archive, color: .orange)
            actionButton(.delete, color: .red)
        }
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.horizontal, Constants.WorkspaceList.pageInset)
                .opacity(dividerOpacity)
                .animation(reduceMotion ? nil : .easeOut(duration: DividerStyle.fadeDuration), value: dividerOpacity)
        }
    }

    private func updateSwipeProgress(_ progress: CGFloat) {
        if progress > 0 {
            workspaceSwipeProgress[workspace.id] = progress
        } else {
            workspaceSwipeProgress.removeValue(forKey: workspace.id)
        }
    }

    private enum DividerStyle {
        static let fadeProgress: CGFloat = 0.15
        static let fadeDuration = 0.12
    }

    private func workspaceButton(swipeProgress: CGFloat) -> some View {
        Button {
            if revealedTarget != nil {
                revealedTarget = nil
            } else {
                onSelect()
            }
        } label: {
            WorkspaceRowView(
                workspace: workspace,
                colorScheme: colorScheme,
                showRepo: showRepo,
                spacious: true,
                timestampOpacity: 1 - Double(swipeProgress)
            )
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
        revealedTarget = nil
        onAction(action)
    }
}
