import SwiftUI

/// A pull request in the spacious workspace-list row style: state icon,
/// title with update time, then number, repository, author and the linked
/// workspace.
struct PullRequestRowView: View {
    let item: PullRequestListItem
    var showsRepository = true
    var linkedWorkspace: Workspace?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .headline) private var titleTracking: CGFloat = -0.36
    @ScaledMetric(relativeTo: .caption) private var avatarSize: CGFloat = 16
    @ScaledMetric(relativeTo: .headline) private var iconSize = Constants.WorkspaceRow.statusIconSize
    private static let iconBaselineRatio: CGFloat = 0.3

    private var secondary: Color {
        Constants.WorkspaceList.secondaryText(for: colorScheme, contrast: contrast)
    }

    var body: some View {
        // Sits the icon's centre on the title's first line, like the status icon.
        let iconBaseline = iconSize * Self.iconBaselineRatio
        HStack(alignment: .firstTextBaseline, spacing: Constants.WorkspaceRow.spaciousRowSpacing) {
            Image(WorkspaceRowView.pillImage(for: item.status))
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .foregroundStyle(stateColor)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + iconBaseline }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Constants.WorkspaceRow.spaciousTitleSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: Constants.WorkspaceRow.metadataSpacing) {
                    Text(item.title)
                        .interFont(Constants.Typography.bodyM.withFace(.semibold))
                        .tracking(titleTracking)
                        .lineLimit(Constants.WorkspaceRow.titleLineLimit)
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let updated = relativeUpdate {
                        Text(updated)
                            .interFont(Constants.Typography.subtextXXS)
                            .foregroundStyle(secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                metadata
            }
        }
        .padding(.vertical, Constants.WorkspaceRow.spaciousPadding)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var metadata: some View {
        HStack(alignment: .center, spacing: Constants.WorkspaceRow.metadataSpacing) {
            Text(showsRepository ? "#\(item.number) · \(item.repo)" : "#\(item.number)")
                .interFont(Constants.Typography.subtextXXS)
                .foregroundStyle(secondary)
                .lineLimit(1)
                .fixedSize()
            if let author = item.author {
                RepoOwnerAvatarView(owner: author, size: avatarSize, fallbackSymbol: "person.fill", cornerRadius: avatarSize / 2)
                    .accessibilityHidden(true)
            }
            if let linkedWorkspace {
                Text(linkedWorkspace.title)
                    .interFont(Constants.Typography.subtextXXS.withFace(.medium))
                    .foregroundStyle(secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, Constants.WorkspaceRow.outlinedPillHorizontalPadding)
                    .padding(.vertical, Constants.WorkspaceRow.pillVerticalPadding)
                    .frame(minHeight: Constants.WorkspaceRow.outlinedPillMinimumHeight)
                    .background(Capsule().fill(Constants.WorkspaceList.controlSurface(for: colorScheme)))
                    .layoutPriority(-1)
                    .accessibilityIdentifier("pullRequests.row.workspace")
            }
        }
    }

    private var stateColor: Color {
        switch item.status {
        case .open: Constants.Colors.WorkspaceStatus.prOpen
        case .merged: Constants.Colors.WorkspaceStatus.prMerged
        case .closed: Theme.destructive(for: colorScheme)
        case .draft: secondary
        }
    }

    private var relativeUpdate: String? {
        ISO8601DateFormatter.lenientDate(from: item.updatedAt)?.relativeFormatted
    }

    private var accessibilityText: String {
        var parts = ["\(item.status.rawValue.capitalized) pull request #\(item.number)", item.title, "\(item.owner)/\(item.repo)"]
        if let author = item.author { parts.append("by \(author)") }
        if let linkedWorkspace { parts.append("Workspace \(linkedWorkspace.title)") }
        if let relativeUpdate { parts.append("Updated \(relativeUpdate)") }
        return parts.joined(separator: ", ")
    }
}
