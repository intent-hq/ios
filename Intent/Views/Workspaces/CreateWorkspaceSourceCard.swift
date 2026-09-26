import SwiftUI

struct CreateWorkspaceSourceCard: View {
    let repositoryFullName: String
    let branch: String
    let onEdit: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .callout) private var folderSize: CGFloat = 20
    @ScaledMetric(relativeTo: .caption) private var chevronSize: CGFloat = 16

    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: CreateWorkspaceFormStyle.controlPadding) {
                Image(.folder)
                    .resizable().scaledToFit()
                    .frame(width: folderSize, height: folderSize)
                    .foregroundStyle(CreateWorkspaceFormStyle.secondary(for: colorScheme, contrast: contrast))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(repositoryFullName)
                        .interFont(Constants.Typography.bodyS)
                    Text("off branch \(Text(branch).foregroundStyle(CreateWorkspaceFormStyle.foreground(for: colorScheme)))")
                        .interFont(Constants.Typography.bodyS)
                        .foregroundStyle(CreateWorkspaceFormStyle.secondary(for: colorScheme, contrast: contrast))
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(.chevronRight)
                    .resizable()
                    .scaledToFit()
                    .frame(width: chevronSize, height: chevronSize)
                    .accessibilityHidden(true)
            }
            .font(.callout)
            .foregroundStyle(CreateWorkspaceFormStyle.foreground(for: colorScheme))
            .multilineTextAlignment(.leading)
            .padding(.horizontal, CreateWorkspaceFormStyle.pagePadding)
            .padding(.vertical, CreateWorkspaceFormStyle.controlPadding)
            .frame(minHeight: CreateWorkspaceFormStyle.sourceHeight)
            .background(CreateWorkspaceFormStyle.card(for: colorScheme), in: .rect(
                cornerRadius: CreateWorkspaceFormStyle.cornerRadius
            ))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("creation.sourceCard")
        .accessibilityLabel("Source. Repository: \(repositoryFullName). Branch: \(branch)")
        .accessibilityHint("Change the branch, or go back again to change the repository.")
    }
}
