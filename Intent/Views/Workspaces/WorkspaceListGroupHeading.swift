import SwiftUI

/// The iPhone Workspaces list's collapsible Repo or Status heading, with the
/// list's group spacing inside the tap target.
struct WorkspaceListGroupHeading: View {
    let title: String
    let mode: ViewMode
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
            Text(title.uppercased())
                .interFont(Constants.Typography.eyebrow)
        }
        .foregroundStyle(Constants.WorkspaceList.secondaryText(for: colorScheme, contrast: colorSchemeContrast))
        .disabled(!isToggleEnabled)
        .accessibilityIdentifier(Self.accessibilityIdentifier(for: title, in: mode))
    }

    /// Shared with the iPad sidebar so UI tests address both the same way.
    static func accessibilityIdentifier(for key: String, in mode: ViewMode) -> String {
        "workspaces.\(mode == .status ? "statusGroup" : "repoGroup").\(key)"
    }
}
