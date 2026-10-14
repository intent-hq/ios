import SwiftUI

struct WorkspaceSearchEmptyState: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: Constants.ModalPicker.emptyStateSpacing) {
            Image(.search)
                .resizable()
                .scaledToFit()
                .frame(width: Constants.WorkspaceSearch.iconSize, height: Constants.WorkspaceSearch.iconSize)
                .accessibilityHidden(true)
            Text("No Results")
                .interFont(Constants.Typography.bodyS.withFace(.bold))
                .foregroundStyle(Theme.foreground(for: colorScheme))
            Text("Check the spelling or try a new search.")
                .interFont(Constants.Typography.bodyS)
        }
        .foregroundStyle(Constants.WorkspaceList.secondaryText(for: colorScheme, contrast: contrast))
        .multilineTextAlignment(.center)
        .padding(Constants.WorkspaceList.pageInset)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("workspaces.search.empty")
    }
}
