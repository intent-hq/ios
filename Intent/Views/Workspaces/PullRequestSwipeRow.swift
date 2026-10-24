import SwiftUI

/// A pull request row with the workspace list's leading swipe: the state
/// icon grows into "Open agent" when a workspace tracks the pull request,
/// otherwise "New workspace", and a completed swipe performs it.
struct PullRequestSwipeRow: View {
    let item: PullRequestListItem
    let showsRepository: Bool
    let linkedWorkspace: Workspace?
    @Binding var revealedTarget: WorkspaceSwipeTarget?
    let onSelect: () -> Void
    let onSwipe: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .headline) private var iconSize = Constants.WorkspaceRow.statusIconSize
    @State private var swipeOffset: CGFloat = 0
    @State private var badgeSize = CGSize(width: 0, height: Constants.WorkspaceList.swipeButtonSize)
    @State private var iconCenter: CGFloat = 0
    @State private var rowSize: CGSize = .zero

    private var inset: CGFloat { Constants.WorkspaceList.pageInset }
    private var leadingLayout: WorkspaceSwipePolicy.LeadingLayout {
        WorkspaceSwipePolicy.leadingLayout(
            rowWidth: rowSize.width,
            badgeWidth: badgeSize.width,
            leadingInset: inset,
            gap: Constants.WorkspaceList.swipeActionsLeadingSpacing
        )
    }
    private var leadingProgress: CGFloat { min(1, max(0, swipeOffset / max(1, leadingLayout.revealWidth))) }
    private var swipeTitle: String { linkedWorkspace == nil ? "New workspace" : "Open agent" }

    var body: some View {
        WorkspaceSwipeContainer(
            target: .pullRequest(item.id),
            revealedTarget: $revealedTarget,
            actionCount: 0,
            horizontalInset: inset,
            swipeBackground: Constants.WorkspaceList.controlSurface(for: colorScheme),
            leadingSwipeWidth: leadingLayout.revealWidth,
            onLeadingSwipeCompleted: onSwipe,
            onOffsetChanged: { swipeOffset = $0 },
            content: { _ in
                Button(action: onSelect) {
                    PullRequestRowView(
                        item: item,
                        showsRepository: showsRepository,
                        linkedWorkspace: linkedWorkspace,
                        iconHidden: true,
                        leadingSwipeProgress: leadingProgress
                    ) { iconCenter = $0 }
                }
                .buttonStyle(IntentContentButtonStyle())
                .accessibilityIdentifier("pullRequests.row.\(item.id)")
            },
            actions: { EmptyView() }
        )
        .onGeometryChange(for: CGSize.self) { $0.size } action: { rowSize = $0 }
        .overlay(alignment: .topLeading) {
            SwipeMorphBadge(
                fill: PullRequestRowView.stateColor(item.status, colorScheme: colorScheme, contrast: contrast),
                image: linkedWorkspace == nil ? .addIcon : .messageList,
                title: swipeTitle,
                progress: leadingProgress,
                availableWidth: leadingLayout.maximumBadgeWidth,
                dotSize: iconSize
            ) { badgeSize = $0 } dot: {
                Image(WorkspaceRowView.pillImage(for: item.status))
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .foregroundStyle(PullRequestRowView.stateColor(item.status, colorScheme: colorScheme, contrast: contrast))
            }
            .offset(
                x: inset + min(0, swipeOffset),
                y: iconCenter + (rowSize.height / 2 - iconCenter) * leadingProgress - iconSize / 2
            )
        }
        .clipped()
        .overlay(alignment: .bottom) {
            Divider().padding(.horizontal, inset)
        }
        .accessibilityAction(named: Text(swipeTitle), onSwipe)
    }
}
