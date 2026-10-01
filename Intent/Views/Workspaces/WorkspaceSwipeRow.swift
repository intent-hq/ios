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
    @State private var badgeSize = CGSize(width: BadgeStyle.initialWidth, height: Constants.WorkspaceList.swipeButtonSize)
    @State private var rowSize: CGSize = .zero

    private var actionSize: CGFloat { max(Constants.Accessibility.minimumTapTarget, scaledActionSize) }
    private var horizontalInset: CGFloat { spacious ? Constants.WorkspaceList.pageInset : 0 }
    private var statusInset: CGFloat { horizontalInset + (spacious ? 0 : Constants.WorkspaceRow.horizontalPadding) }
    private var leadingLayout: WorkspaceSwipePolicy.LeadingLayout {
        WorkspaceSwipePolicy.leadingLayout(
            rowWidth: rowSize.width,
            badgeWidth: badgeSize.width,
            leadingInset: statusInset,
            gap: Constants.WorkspaceList.swipeActionsLeadingSpacing
        )
    }
    private var leadingWidth: CGFloat { leadingLayout.revealWidth }
    private var leadingProgress: CGFloat { min(1, max(0, swipeOffset / max(1, leadingWidth))) }

    private var dividerOpacity: Double {
        let progress = workspaceSwipeProgress[workspace.id, default: 0]
        let nextProgress = nextWorkspaceId.flatMap { workspaceSwipeProgress[$0] } ?? 0
        return Double(1 - min(1, max(progress, nextProgress) / DividerStyle.fadeProgress))
    }

    var body: some View {
        let titleCenter = WorkspaceRowView.titleCenter
        let badgeProgress = leadingProgress

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
        .alignmentGuide(titleCenter) { dimensions in
            let statusCenter = dimensions[titleCenter]
            return statusCenter + (dimensions.height / 2 - statusCenter) * badgeProgress
        }
        .overlay(alignment: Alignment(horizontal: .leading, vertical: titleCenter)) {
            WorkspaceStatusSwipeBadge(
                workspace: workspace,
                progress: leadingProgress,
                availableWidth: leadingLayout.maximumBadgeWidth
            ) { badgeSize = $0 }
            .offset(x: statusInset + min(0, swipeOffset))
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
                minimumHeight: badgeSize.height,
                leadingSwipeProgress: leadingProgress
            )
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
