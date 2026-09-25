import SwiftUI

struct CreateWorkspaceSourceCard: View {
    let repositoryFullName: String
    let branch: String
    let onEdit: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: onEdit) {
            HStack(spacing: CreateWorkspaceFormStyle.controlPadding) {
                Image(systemName: "folder")
                    .foregroundStyle(CreateWorkspaceFormStyle.secondary(for: colorScheme, contrast: contrast))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(repositoryFullName)
                    Text("off branch \(Text(branch).foregroundStyle(CreateWorkspaceFormStyle.foreground(for: colorScheme)))")
                        .foregroundStyle(CreateWorkspaceFormStyle.secondary(for: colorScheme, contrast: contrast))
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
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
