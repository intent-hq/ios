import SwiftUI

struct CreateWorkspaceChoiceLabel: View {
    let title: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: CreateWorkspaceFormStyle.rowSpacing) {
            Text(title)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.down")
                .font(.caption.weight(.semibold))
                .accessibilityHidden(true)
        }
        .font(.callout)
        .foregroundStyle(CreateWorkspaceFormStyle.foreground(for: colorScheme))
        .multilineTextAlignment(.leading)
        .padding(.horizontal, CreateWorkspaceFormStyle.controlPadding)
        .padding(.vertical, CreateWorkspaceFormStyle.controlVerticalPadding)
        .frame(minHeight: CreateWorkspaceFormStyle.controlHeight)
        .background(CreateWorkspaceFormStyle.card(for: colorScheme), in: .rect(
            cornerRadius: CreateWorkspaceFormStyle.cornerRadius
        ))
        .contentShape(.rect)
    }
}
