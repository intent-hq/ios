import SwiftUI

/// The iPhone Workspaces list's collapsible repo heading. It matches the list's
/// other group headings, with the group spacing inside the tap target.
struct WorkspaceListRepoGroupHeading: View {
    let repoName: String
    let isExpanded: Bool
    /// False while searching: groups are forced open.
    let isToggleEnabled: Bool
    let onToggle: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        CollapsibleSectionHeader(
            isExpanded: isExpanded,
            insets: EdgeInsets(
                top: Constants.WorkspaceList.groupTopSpacing,
                leading: Constants.WorkspaceList.pageInset,
                bottom: Constants.WorkspaceList.groupBottomSpacing,
                trailing: Constants.WorkspaceList.pageInset
            ),
            onToggle: onToggle
        ) {
            Text(repoName.uppercased())
                .interFont(Constants.Typography.eyebrow)
        }
        .foregroundStyle(Constants.WorkspaceList.secondaryText(for: colorScheme, contrast: colorSchemeContrast))
        .disabled(!isToggleEnabled)
        .accessibilityIdentifier("workspaces.repoGroup.\(repoName)")
    }
}
