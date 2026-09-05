import SwiftUI

struct WorkspaceRowView: View {
    let workspace: Workspace
    let colorScheme: ColorScheme
    var showRepo: Bool = true
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    /// Workspace-scoped PR monitors feeding the pill pool and the "+N"
    /// indicator; the owning list provides the shared store.
    private let monitorsSource = WorkspacePrMonitorsStore.shared

    private var prIndicator: PrIndicatorModel {
        Self.derivePrIndicator(
            workspace: workspace,
            monitors: monitorsSource.monitors(for: workspace.id))
    }

    var body: some View {
        HStack(spacing: Constants.WorkspaceRow.rowSpacing) {
            // Status icon with agent activity / unread dot overlays
            WorkspaceStatusIconView(workspace: workspace, colorScheme: colorScheme)

            VStack(alignment: .leading, spacing: Constants.WorkspaceRow.titleSpacing) {
                if workspace.title.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("<Untitled>")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.mutedForeground(
                            for: colorScheme, contrast: colorSchemeContrast))
                        .lineLimit(2)
                } else {
                    Text(workspace.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                        .lineLimit(2)
                }

                HStack(spacing: Constants.WorkspaceRow.metadataSpacing) {
                    if showRepo, let repo = workspace.repositoryName {
                        Text(repo)
                            .font(.caption)
                            .foregroundStyle(Theme.mutedForeground(
                                for: colorScheme, contrast: colorSchemeContrast))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(-1)
                    }

                    if let pill = prIndicator.pill {
                        let pillColor = Self.pillColor(for: pill.status)
                        HStack(spacing: 3) {
                            Image(systemName: Self.pillSystemImage(for: pill.status))
                            Text("PR\(pill.number.map { " #\($0)" } ?? "")")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(pillColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, Constants.WorkspaceRow.pillHorizontalPadding)
                        .padding(.vertical, Constants.WorkspaceRow.pillVerticalPadding)
                        .background(pillColor.opacity(Constants.WorkspaceRow.pillBackgroundOpacity))
                        .clipShape(Capsule())
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(
                            "\(pill.status.rawValue.capitalized) pull request"
                                + (pill.number.map { " #\($0)" } ?? ""))
                    }

                    // "+N": other monitored PRs in the pool beyond the
                    // primary pill (same capsule styling, muted).
                    if prIndicator.otherMonitorCount > 0 {
                        Text("+\(prIndicator.otherMonitorCount)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.mutedForeground(
                                for: colorScheme, contrast: colorSchemeContrast))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, Constants.WorkspaceRow.pillHorizontalPadding)
                            .padding(.vertical, Constants.WorkspaceRow.pillVerticalPadding)
                            .background(Theme.mutedForeground(
                                for: colorScheme, contrast: colorSchemeContrast).opacity(
                                    Constants.WorkspaceRow.pillBackgroundOpacity))
                            .clipShape(Capsule())
                    }
                }
            }
            .layoutPriority(1)

            Spacer()

            if let activity = workspace.lastActivity ?? workspace.updatedAt {
                Text(relativeDate(from: activity))
                    .font(.caption)
                    .foregroundStyle(Theme.mutedForeground(
                        for: colorScheme, contrast: colorSchemeContrast))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, Constants.WorkspaceRow.verticalPadding)
        .padding(.horizontal, Constants.WorkspaceRow.horizontalPadding)
        .task {
            await monitorsSource.seed(workspaceId: workspace.id)
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
