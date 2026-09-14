import SwiftUI

struct WorkspaceRowView: View {
    let workspace: Workspace
    let colorScheme: ColorScheme
    var showRepo: Bool = true
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Workspace-scoped PR monitors feeding the pill pool and the "+N"
    /// indicator, read from the window's session so pinned windows use their
    /// own backend; falls back to the shared store when no session is in the
    /// environment (previews/tests).
    @Environment(BackendSession.self) private var session: BackendSession?

    private var monitorsSource: WorkspacePrMonitorsStore {
        session?.prMonitorsStore ?? .shared
    }

    private var prIndicator: PrIndicatorModel {
        Self.derivePrIndicator(
            workspace: workspace,
            monitors: monitorsSource.monitors(for: workspace.id)
        )
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Constants.WorkspaceRow.rowSpacing) {
            // Status icon with agent activity / unread dot overlays
            WorkspaceStatusIconView(workspace: workspace, colorScheme: colorScheme)
                .alignmentGuide(.firstTextBaseline) { dimensions in
                    dimensions[.bottom]
                }

            VStack(alignment: .leading, spacing: Constants.WorkspaceRow.titleSpacing) {
                title

                if Self.usesExpandedMetadataLayout(for: dynamicTypeSize) {
                    expandedMetadata
                } else {
                    compactMetadata
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .padding(.vertical, Constants.WorkspaceRow.verticalPadding)
        .padding(.horizontal, Constants.WorkspaceRow.horizontalPadding)
        .visionAttentionCue(workspaceNeedsInput(workspace))
        .task {
            await monitorsSource.seed(workspaceId: workspace.id)
        }
    }

    nonisolated static func usesExpandedMetadataLayout(for size: DynamicTypeSize) -> Bool {
        size.isAccessibilitySize
    }

    nonisolated static func titleLineLimit(for size: DynamicTypeSize) -> Int? {
        usesExpandedMetadataLayout(for: size) ? nil : 2
    }

    nonisolated static func additionalPullRequestsAccessibilityLabel(_ count: Int) -> String {
        count == 1 ? "1 additional pull request" : "\(count) additional pull requests"
    }

    @ViewBuilder
    private var title: some View {
        let isUntitled = workspace.title.trimmingCharacters(in: .whitespaces).isEmpty
        Text(isUntitled ? "<Untitled>" : workspace.title)
            .font(.headline)
            .foregroundStyle(isUntitled
                ? Theme.mutedForeground(for: colorScheme, contrast: colorSchemeContrast)
                : Theme.foreground(for: colorScheme))
            .lineLimit(Self.titleLineLimit(for: dynamicTypeSize))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var compactMetadata: some View {
        HStack(alignment: .firstTextBaseline, spacing: Constants.WorkspaceRow.metadataSpacing) {
            repositoryLabel(lineLimit: 1)
            pullRequestBadges(expanded: false)
            Spacer(minLength: Constants.WorkspaceRow.metadataSpacing)
            timestampLabel
        }
    }

    private var expandedMetadata: some View {
        VStack(alignment: .leading, spacing: Constants.WorkspaceRow.titleSpacing) {
            repositoryLabel(lineLimit: nil)
                .fixedSize(horizontal: false, vertical: true)
            pullRequestBadges(expanded: true)
            timestampLabel
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func repositoryLabel(lineLimit: Int?) -> some View {
        if showRepo, let repo = workspace.repositoryName {
            Text(repo)
                .font(.caption)
                .foregroundStyle(Theme.mutedForeground(
                    for: colorScheme,
                    contrast: colorSchemeContrast
                ))
                .lineLimit(lineLimit)
                .truncationMode(.middle)
                .layoutPriority(-1)
                .accessibilityLabel("Repository \(repo)")
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
    }

    struct PullRequestBadges: View {
        let indicator: PrIndicatorModel
        let colorScheme: ColorScheme
        let colorSchemeContrast: ColorSchemeContrast
        let expanded: Bool

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
                alignment: .firstTextBaseline,
                spacing: Constants.WorkspaceRow.metadataSpacing
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
                    alignment: .firstTextBaseline,
                    spacing: Constants.WorkspaceRow.titleSpacing
                ) {
                    Image(systemName: WorkspaceRowView.pillSystemImage(for: pill.status))
                        .foregroundStyle(pillColor)
                    Text("PR\(pill.number.map { " #\($0)" } ?? "")")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.mutedForeground(
                    for: colorScheme,
                    contrast: colorSchemeContrast
                ))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, Constants.WorkspaceRow.pillHorizontalPadding)
                .padding(.vertical, Constants.WorkspaceRow.pillVerticalPadding)
                .background(Theme.muted(for: colorScheme), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(
                        Theme.border(
                            for: colorScheme,
                            contrast: colorSchemeContrast
                        ),
                        lineWidth: colorSchemeContrast == .increased ? 1 : 0.5
                    )
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "\(pill.status.rawValue.capitalized) pull request"
                        + (pill.number.map { " #\($0)" } ?? "")
                )
            }

            if indicator.otherMonitorCount > 0 {
                Text("+\(indicator.otherMonitorCount)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.mutedForeground(
                        for: colorScheme,
                        contrast: colorSchemeContrast
                    ))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, Constants.WorkspaceRow.pillHorizontalPadding)
                    .padding(.vertical, Constants.WorkspaceRow.pillVerticalPadding)
                    .background(Theme.muted(for: colorScheme), in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(
                            Theme.border(
                                for: colorScheme,
                                contrast: colorSchemeContrast
                            ),
                            lineWidth: colorSchemeContrast == .increased ? 1 : 0.5
                        )
                    }
                    .accessibilityLabel(WorkspaceRowView.additionalPullRequestsAccessibilityLabel(
                        indicator.otherMonitorCount
                    ))
            }
        }
    }

    @ViewBuilder
    private var timestampLabel: some View {
        if let activity = workspace.lastActivity ?? workspace.updatedAt {
            let value = relativeDate(from: activity)
            Text(value)
                .font(.caption)
                .foregroundStyle(Theme.mutedForeground(
                    for: colorScheme,
                    contrast: colorSchemeContrast
                ))
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel("Updated \(value)")
        }
    }

    private func relativeDate(from isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: isoString) else {
            // Try without fractional seconds
            let basic = ISO8601DateFormatter()
            guard let date = basic.date(from: isoString) else { return isoString }
            return date.relativeFormatted
        }
        return date.relativeFormatted
    }
}
