import SwiftUI

struct WorkspaceSwipeRow: View {
    let workspace: Workspace
    let showRepo: Bool
    let isUpdating: Bool
    @Binding var revealedTarget: WorkspaceSwipeTarget?
    @Binding var workspaceSwipeProgress: [String: CGFloat]
    let nextWorkspaceId: String?
    var spacious = true
    var showsTrailingActions = true
    let onSelect: () -> Void
    let onOpenRecentAgent: () -> Void
    let onAction: (WorkspaceAction) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var scaledActionSize = Constants.WorkspaceList.swipeButtonSize
    @ScaledMetric(relativeTo: .body) private var actionIconSize = Constants.WorkspaceList.swipeButtonIconSize
    @State private var swipeOffset: CGFloat = 0
    @State private var badgeWidth: CGFloat = BadgeStyle.initialWidth
    @State private var statusCenter: CGFloat = 0
    @State private var rowSize: CGSize = .zero

    private var actionSize: CGFloat { max(Constants.Accessibility.minimumTapTarget, scaledActionSize) }
    private var horizontalInset: CGFloat { spacious ? Constants.WorkspaceList.pageInset : 0 }
    private var leadingWidth: CGFloat {
        min(badgeWidth + Constants.WorkspaceList.swipeActionsLeadingSpacing + horizontalInset, max(actionSize, rowSize.width * BadgeStyle.maximumSwipeFraction))
    }
    private var leadingProgress: CGFloat { min(1, max(0, swipeOffset / max(1, leadingWidth))) }

    private var dividerOpacity: Double {
        let progress = workspaceSwipeProgress[workspace.id, default: 0]
        let nextProgress = nextWorkspaceId.flatMap { workspaceSwipeProgress[$0] } ?? 0
        return Double(1 - min(1, max(progress, nextProgress) / DividerStyle.fadeProgress))
    }

    var body: some View {
        WorkspaceSwipeContainer(
            target: .workspace(workspace.id),
            revealedTarget: $revealedTarget,
            actionCount: showsTrailingActions ? 2 : 0,
            actionWidth: actionSize,
            actionLeadingSpacing: Constants.WorkspaceList.swipeActionsLeadingSpacing,
            horizontalInset: horizontalInset,
            swipeBackground: Constants.WorkspaceList.controlSurface(for: colorScheme),
            leadingSwipeWidth: leadingWidth,
            isSwipeEnabled: !isUpdating,
            onLeadingSwipeCompleted: onOpenRecentAgent,
            onOffsetChanged: updateOffset,
            onSwipeProgressChanged: updateSwipeProgress
        ) { progress in
            workspaceButton(swipeProgress: progress)
        } actions: {
            actionButton(.archive)
            actionButton(.delete)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { rowSize = $0 }
        .overlay(alignment: .topLeading) {
            WorkspaceStatusSwipeBadge(
                workspace: workspace,
                progress: leadingProgress,
                availableWidth: max(actionSize, rowSize.width - 2 * horizontalInset - Constants.WorkspaceList.swipeActionsLeadingSpacing)
            ) { badgeWidth = $0 }
            .offset(
                x: horizontalInset + (spacious ? 0 : Constants.WorkspaceRow.horizontalPadding) + min(0, swipeOffset),
                y: statusCenter + (rowSize.height / 2 - statusCenter) * leadingProgress - Constants.WorkspaceRow.statusIconSize / 2
            )
        }
        .clipped()
        .overlay(alignment: .bottom) {
            if spacious {
                Divider()
                    .padding(.horizontal, Constants.WorkspaceList.pageInset)
                    .opacity(dividerOpacity)
                    .animation(reduceMotion ? nil : .easeOut(duration: DividerStyle.fadeDuration), value: dividerOpacity)
            }
        }
    }

    private func updateSwipeProgress(_ progress: CGFloat) {
        if progress > 0 {
            workspaceSwipeProgress[workspace.id] = progress
        } else {
            workspaceSwipeProgress.removeValue(forKey: workspace.id)
        }
    }

    private func updateOffset(_ offset: CGFloat) { swipeOffset = offset }

    private enum DividerStyle {
        static let fadeProgress: CGFloat = 0.15
        static let fadeDuration = 0.12
    }

    private enum BadgeStyle {
        static let initialWidth: CGFloat = 136
        static let maximumSwipeFraction: CGFloat = 0.7
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
                spacious: spacious,
                timestampOpacity: 1 - Double(swipeProgress),
                statusIconHidden: true,
                leadingSwipeProgress: leadingProgress
            ) { statusCenter = $0 }
                .overlay(alignment: .trailing) {
                    if isUpdating { ProgressView().padding(.trailing) }
                }
        }
        .buttonStyle(.plain)
        .disabled(isUpdating)
        .accessibilityIdentifier("workspace.row.\(workspace.id)")
        .accessibilityValue(WorkspaceStatusIconView.accessibilitySummary(for: workspace))
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
            Button("Open most recent agent", systemImage: "bubble.left") {
                revealedTarget = nil
                onOpenRecentAgent()
            }
            if showsTrailingActions {
                Button("Archive workspace", systemImage: "archivebox") { select(.archive) }
                Button("Delete workspace", systemImage: "trash", role: .destructive) { select(.delete) }
            }
        }
        .disabled(isUpdating)
    }

    private func select(_ action: WorkspaceAction) {
        revealedTarget = nil
        onAction(action)
    }
}
