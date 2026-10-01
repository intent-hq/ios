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
    @ScaledMetric(relativeTo: .body) private var scaledActionSize = Constants.WorkspaceList.swipeButtonSize
    @ScaledMetric(relativeTo: .body) private var actionIconSize = Constants.WorkspaceList.swipeButtonIconSize

    private var actionSize: CGFloat { max(Constants.Accessibility.minimumTapTarget, scaledActionSize) }

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
            actionWidth: actionSize,
            actionLeadingSpacing: Constants.WorkspaceList.swipeActionsLeadingSpacing,
            horizontalInset: Constants.WorkspaceList.pageInset,
            swipeBackground: Constants.WorkspaceList.controlSurface(for: colorScheme),
            onSwipeProgressChanged: updateSwipeProgress
        ) { progress in
            workspaceButton(swipeProgress: progress)
        } actions: {
            actionButton(.archive)
            actionButton(.delete)
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

    private func actionButton(_ action: WorkspaceAction) -> some View {
        Button(role: action == .delete ? .destructive : nil) { select(action) } label: {
            Image(action == .archive ? .archive : .delete)
                .resizable()
                .scaledToFit()
                .frame(width: actionIconSize, height: actionIconSize)
        }
        .buttonStyle(WorkspaceSwipeIconButtonStyle(size: actionSize))
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
