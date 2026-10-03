import SwiftUI

struct WorkspaceRowView: View {
    let workspace: Workspace
    let colorScheme: ColorScheme
    var showRepo: Bool = true
    var spacious = false
    var timestampOpacity: Double = 1
    var statusIconHidden = false
    var minimumHeight: CGFloat = 0
    var leadingSwipeProgress: CGFloat = 0
    var onStatusCenterChanged: (CGFloat) -> Void = { _ in }
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Workspace-scoped PR monitors feeding the pill pool and the "+N"
    /// indicator, read from the window's session so pinned windows use their
    /// own backend; falls back to the shared store when no session is in the
    /// environment (previews/tests).
    @Environment(BackendSession.self) private var session: BackendSession?
    @State private var monitorConsumer = UUID()
    @ScaledMetric(relativeTo: .headline) private var titleTracking: CGFloat = -0.36

    private enum TitleCenterAlignment: AlignmentID {
        nonisolated static func defaultValue(in dimensions: ViewDimensions) -> CGFloat {
            dimensions[VerticalAlignment.center]
        }
    }

    private static let titleCenter = VerticalAlignment(TitleCenterAlignment.self)

    private var monitorsSource: WorkspacePrMonitorsStore {
        session?.prMonitorsStore ?? .shared
    }

    private var prIndicator: PrIndicatorModel {
        Self.derivePrIndicator(
            workspace: workspace,
            monitors: monitorsSource.monitors(for: workspace.id)
        )
    }

    @ViewBuilder private var monitorRefreshButton: some View {
        if monitorsSource.error(for: workspace.id) != nil {
            Button {
                Task { await monitorsSource.refetch(workspaceId: workspace.id) }
            } label: {
                Image(systemName: "exclamationmark.triangle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("PR monitors may be out of date. Retry refresh")
        }
    }

    var body: some View {
        HStack(alignment: Self.titleCenter, spacing: spacious ? Constants.WorkspaceRow.spaciousRowSpacing : Constants.WorkspaceRow.rowSpacing) {
            // Status icon with agent activity / unread dot overlays
            WorkspaceStatusIconView(workspace: workspace, colorScheme: colorScheme)
                .opacity(statusIconHidden ? 0 : 1)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.frame(in: .named(workspace.id)).midY
                } action: { onStatusCenterChanged($0) }

            VStack(alignment: .leading, spacing: spacious ? Constants.WorkspaceRow.spaciousTitleSpacing : Constants.WorkspaceRow.titleSpacing) {
                titleRow

                if hasMetadata {
                    if Self.usesExpandedMetadataLayout(for: dynamicTypeSize) {
                        expandedMetadata
                    } else {
                        compactMetadata
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            monitorRefreshButton
        }
        .offset(x: -(Constants.WorkspaceRow.statusIconSize + (spacious ? Constants.WorkspaceRow.spaciousRowSpacing : Constants.WorkspaceRow.rowSpacing)) * leadingSwipeProgress)
        .contentShape(Rectangle())
        .padding(.vertical, spacious ? Constants.WorkspaceRow.spaciousPadding : Constants.WorkspaceRow.verticalPadding)
        .padding(.horizontal, spacious ? 0 : Constants.WorkspaceRow.horizontalPadding)
        .frame(minHeight: minimumHeight)
        .coordinateSpace(name: workspace.id)
        .visionAttentionCue(workspaceNeedsInput(workspace))
        .task(id: workspace.id) {
            guard !Task.isCancelled else { return }
            monitorsSource.retain(workspaceId: workspace.id, consumer: monitorConsumer)
            await monitorsSource.seed(workspaceId: workspace.id)
        }
        .onChange(of: workspace.id) { previous, _ in
            monitorsSource.release(workspaceId: previous, consumer: monitorConsumer)
        }
        .onDisappear {
            monitorsSource.release(workspaceId: workspace.id, consumer: monitorConsumer)
        }
    }

    private var hasMetadata: Bool {
        let hasRepository = showRepo && workspace.repositoryName != nil
        let hasPullRequests = prIndicator.pill != nil || prIndicator.otherMonitorCount > 0
        let hasActivityLabel = workspace.status == "archived" || workspace.lastActivity != nil || workspace.updatedAt != nil
        let showsMetadataActivity = !spacious || Self.usesExpandedMetadataLayout(for: dynamicTypeSize)
        return hasRepository || hasPullRequests || (hasActivityLabel && showsMetadataActivity)
    }

    nonisolated static func usesExpandedMetadataLayout(for size: DynamicTypeSize) -> Bool {
        size.isAccessibilitySize
    }

    nonisolated static func titleLineLimit(for size: DynamicTypeSize) -> Int? {
        usesExpandedMetadataLayout(for: size) ? nil : Constants.WorkspaceRow.titleLineLimit
    }

    nonisolated static func additionalPullRequestsAccessibilityLabel(_ count: Int) -> String {
        count == 1 ? "1 additional pull request" : "\(count) additional pull requests"
    }

    /// Stable identifiers for the PR badges so tests and automation locate them
    /// without depending on the spoken label or layout position.
    enum BadgeIdentifier {
        static let pullRequest = "workspaceRow.prBadge"
        static let additionalPullRequests = "workspaceRow.prBadge.additional"
    }

    @ViewBuilder
    private var titleRow: some View {
        if spacious, !Self.usesExpandedMetadataLayout(for: dynamicTypeSize) {
            HStack(alignment: .firstTextBaseline, spacing: Constants.WorkspaceRow.metadataSpacing) {
                title
                    .frame(maxWidth: .infinity, alignment: .leading)
                activityLabel
            }
        } else {
            title
        }
    }

    @ViewBuilder
    private var title: some View {
        let isUntitled = workspace.title.trimmingCharacters(in: .whitespaces).isEmpty
        Text(isUntitled ? "<Untitled>" : workspace.title)
            .interFont(Constants.Typography.bodyM.withFace(.semibold))
            .tracking(titleTracking)
            .foregroundStyle(isUntitled
                ? Theme.mutedForeground(for: colorScheme, contrast: colorSchemeContrast)
                : Theme.foreground(for: colorScheme))
            .lineLimit(Self.titleLineLimit(for: dynamicTypeSize))
            .fixedSize(horizontal: false, vertical: true)
            .alignmentGuide(Self.titleCenter) { dimensions in
                dimensions[VerticalAlignment.center]
            }
    }

    private var compactMetadata: some View {
        HStack(alignment: .firstTextBaseline, spacing: Constants.WorkspaceRow.metadataSpacing) {
            repositoryLabel(lineLimit: 1)
            pullRequestBadges(expanded: false)
            if !spacious {
                Spacer(minLength: Constants.WorkspaceRow.metadataSpacing)
                activityLabel
            }
        }
    }

    private var expandedMetadata: some View {
        VStack(alignment: .leading, spacing: Constants.WorkspaceRow.titleSpacing) {
            repositoryLabel(lineLimit: nil)
                .fixedSize(horizontal: false, vertical: true)
            pullRequestBadges(expanded: true)
            activityLabel
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func repositoryLabel(lineLimit: Int?) -> some View {
        if showRepo, let repo = workspace.repositoryName {
            let displayName = workspace.repositoryOwner.map { "\($0)/\(repo)" } ?? repo
            Text(displayName)
                .interFont(Constants.Typography.subtextXXS)
                .foregroundStyle(Theme.mutedForeground(
                    for: colorScheme,
                    contrast: colorSchemeContrast
                ))
                .lineLimit(lineLimit)
                .truncationMode(.middle)
                .layoutPriority(-1)
                .accessibilityLabel("Repository \(displayName)")
        }
    }

    @ViewBuilder
    private func pullRequestBadges(expanded: Bool) -> some View {
        PullRequestBadges(
            indicator: prIndicator,
            colorScheme: colorScheme,
            colorSchemeContrast: colorSchemeContrast,
            expanded: expanded
        )
        .offset(y: spacious ? Constants.WorkspaceRow.spaciousBadgeVerticalOffset : 0)
    }

    struct PullRequestBadges: View {
        let indicator: PrIndicatorModel
        let colorScheme: ColorScheme
        let colorSchemeContrast: ColorSchemeContrast
        let expanded: Bool
        @ScaledMetric(relativeTo: .caption) private var iconSize = Constants.WorkspaceRow.pillIconSize
        @ScaledMetric(relativeTo: .caption) private var tracking: CGFloat = 0.24

        var body: some View {
            if expanded {
                ViewThatFits(in: .horizontal) {
                    horizontalBadges
                    verticalBadges
                }
            } else {
                horizontalBadges
            }
        }

        private var horizontalBadges: some View {
            HStack(
                alignment: .center,
                spacing: Constants.WorkspaceRow.pillSpacing
            ) {
                badgeContent
            }
        }

        private var verticalBadges: some View {
            VStack(alignment: .leading, spacing: Constants.WorkspaceRow.titleSpacing) {
                badgeContent
            }
        }

        @ViewBuilder
        private var badgeContent: some View {
            if let pill = indicator.pill {
                let pillColor = WorkspaceRowView.pillColor(for: pill.status)
                HStack(
                    alignment: .center,
                    spacing: Constants.WorkspaceRow.pillIconSpacing
                ) {
                    Image(WorkspaceRowView.pillImage(for: pill.status))
                        .resizable()
                        .scaledToFit()
                        .frame(width: iconSize, height: iconSize)
                        .foregroundStyle(pillColor)
                        .accessibilityHidden(true)
                    Text("PR\(pill.number.map { " #\($0)" } ?? "")")
                        .interFont(Constants.Typography.subtextXXS.withFace(.medium))
                        .tracking(tracking)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.mutedForeground(
                    for: colorScheme,
                    contrast: colorSchemeContrast
                ))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, Constants.WorkspaceRow.outlinedPillHorizontalPadding)
                .padding(.vertical, Constants.WorkspaceRow.pillVerticalPadding)
                .frame(minHeight: Constants.WorkspaceRow.outlinedPillMinimumHeight)
                .overlay { pillOutline }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(pill.status.rawValue.capitalized) pull request"
                        + (pill.number.map { " #\($0)" } ?? "")
                )
                .accessibilityIdentifier(BadgeIdentifier.pullRequest)
            }

            if indicator.otherMonitorCount > 0 {
                Text("+\(indicator.otherMonitorCount)")
                    .interFont(Constants.Typography.subtextXXS.withFace(.medium))
                    .tracking(tracking)
                    .foregroundStyle(Theme.mutedForeground(
                        for: colorScheme,
                        contrast: colorSchemeContrast
                    ))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, Constants.WorkspaceRow.outlinedPillHorizontalPadding)
                    .padding(.vertical, Constants.WorkspaceRow.pillVerticalPadding)
                    .frame(minHeight: Constants.WorkspaceRow.outlinedPillMinimumHeight)
                    .overlay { pillOutline }
                    .accessibilityLabel(WorkspaceRowView.additionalPullRequestsAccessibilityLabel(
                        indicator.otherMonitorCount
                    ))
                    .accessibilityIdentifier(BadgeIdentifier.additionalPullRequests)
            }
        }

        private var pillOutline: some View {
            Capsule().strokeBorder(
                colorSchemeContrast == .increased
                    ? Theme.border(for: colorScheme, contrast: colorSchemeContrast)
                    : (colorScheme == .dark ? Color.white : Color.black).opacity(Constants.WorkspaceRow.pillOutlineOpacity),
                lineWidth: colorSchemeContrast == .increased
                    ? Constants.WorkspaceRow.increasedContrastPillBorderWidth
                    : Constants.WorkspaceRow.pillBorderWidth
            )
        }
    }

    @ViewBuilder
    private var activityLabel: some View {
        if workspace.status == "archived" {
            archivedBadge
                .opacity(timestampOpacity)
        } else if let activity = workspace.lastActivity ?? workspace.updatedAt {
            let value = relativeDate(from: activity)
            Text(value)
                .interFont(Constants.Typography.subtextXXS)
                .foregroundStyle(Theme.mutedForeground(
                    for: colorScheme,
                    contrast: colorSchemeContrast
                ))
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel("Updated \(value)")
                .opacity(timestampOpacity)
        }
    }
}

private extension WorkspaceRowView {
    var archivedBadge: some View {
        Text("Archived")
            .interFont(Constants.Typography.subtextXXS.withFace(.medium))
            .foregroundStyle(Theme.mutedForeground(for: colorScheme, contrast: colorSchemeContrast))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, Constants.WorkspaceRow.outlinedPillHorizontalPadding)
            .padding(.vertical, Constants.WorkspaceRow.pillVerticalPadding)
            .frame(minHeight: Constants.WorkspaceRow.outlinedPillMinimumHeight)
            .overlay {
                Capsule().strokeBorder(
                    colorSchemeContrast == .increased
                        ? Theme.border(for: colorScheme, contrast: colorSchemeContrast)
                        : (colorScheme == .dark ? Color.white : Color.black).opacity(Constants.WorkspaceRow.pillOutlineOpacity),
                    lineWidth: colorSchemeContrast == .increased
                        ? Constants.WorkspaceRow.increasedContrastPillBorderWidth
                        : Constants.WorkspaceRow.pillBorderWidth
                )
            }
            .accessibilityIdentifier("workspaceRow.archivedBadge")
    }

    func relativeDate(from isoString: String) -> String {
        guard let date = ISO8601DateFormatter.lenientDate(from: isoString) else { return isoString }
        return date.relativeFormatted
    }
}
