import SwiftUI

private enum RepoGroupDisclosureStyle {
    static let minimumHitHeight: CGFloat = 44
    static let chevronSize: CGFloat = 12
    static let chevronSpacing: CGFloat = 4
    static let expandedRotation: Double = 90
    static let animationDuration: Double = 0.2
}

/// A repo group heading in the Workspaces Repo view that collapses or expands
/// the group's rows. Shared by the iPhone list and the iPad sidebar.
struct RepoGroupDisclosureButton<Label: View>: View {
    let repoKey: String
    let isExpanded: Bool
    /// False while searching: groups are forced open, so toggling is disabled.
    let isToggleEnabled: Bool
    /// Spacing around the heading that still belongs to the tap target.
    var insets = EdgeInsets()
    let action: () -> Void
    @ViewBuilder let label: Label

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var chevronSize = RepoGroupDisclosureStyle.chevronSize
    @ScaledMetric(relativeTo: .caption) private var chevronSpacing = RepoGroupDisclosureStyle.chevronSpacing

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: RepoGroupDisclosureStyle.animationDuration)) { action() }
        } label: {
            HStack(spacing: chevronSpacing) {
                label
                Image(.chevronRight)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: chevronSize, height: chevronSize)
                    .rotationEffect(.degrees(isExpanded ? RepoGroupDisclosureStyle.expandedRotation : 0))
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .padding(insets)
            .frame(minHeight: RepoGroupDisclosureStyle.minimumHitHeight, alignment: .bottomLeading)
            .contentShape(.rect)
        }
        .buttonStyle(IntentContentButtonStyle())
        .disabled(!isToggleEnabled)
        .accessibilityLabel(Text(repoKey))
        .accessibilityValue(Text(isExpanded ? "Expanded" : "Collapsed"))
        .accessibilityHint(Text(isExpanded ? "Collapses this repository's workspaces" : "Expands this repository's workspaces"))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("workspaces.repoGroup.\(repoKey)")
    }
}

/// The iPhone Workspaces list's repo heading: uppercased eyebrow text with the
/// list's group spacing inside the tap target.
struct WorkspaceListRepoGroupHeading: View {
    let repoName: String
    let isExpanded: Bool
    let isToggleEnabled: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        RepoGroupDisclosureButton(
            repoKey: repoName,
            isExpanded: isExpanded,
            isToggleEnabled: isToggleEnabled,
            insets: EdgeInsets(
                top: Constants.WorkspaceList.groupTopSpacing,
                leading: Constants.WorkspaceList.pageInset,
                bottom: Constants.WorkspaceList.groupBottomSpacing,
                trailing: Constants.WorkspaceList.pageInset
            ),
            action: action
        ) {
            Text(repoName.uppercased())
                .interFont(Constants.Typography.eyebrow)
        }
        .foregroundStyle(Constants.WorkspaceList.secondaryText(for: colorScheme, contrast: colorSchemeContrast))
    }
}
