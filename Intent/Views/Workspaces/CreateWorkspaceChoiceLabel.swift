import SwiftUI

struct CreateWorkspaceChoiceLabel: View {
    let title: String
    var surface: Color?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .caption) private var chevronSize: CGFloat = 16

    var body: some View {
        HStack(spacing: CreateWorkspaceFormStyle.rowSpacing) {
            Text(title)
                .interFont(Constants.Typography.bodyS)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(.chevronDown)
                .resizable()
                .scaledToFit()
                .frame(width: chevronSize, height: chevronSize)
                .accessibilityHidden(true)
        }
        .foregroundStyle(isEnabled
            ? CreateWorkspaceFormStyle.foreground(for: colorScheme)
            : CreateWorkspaceFormStyle.disabledForeground(for: colorScheme))
        .multilineTextAlignment(.leading)
        .padding(.horizontal, CreateWorkspaceFormStyle.controlPadding)
        .padding(.vertical, CreateWorkspaceFormStyle.controlVerticalPadding)
        .frame(minHeight: CreateWorkspaceFormStyle.controlHeight)
        .background(surface ?? CreateWorkspaceFormStyle.card(for: colorScheme), in: .rect(
            cornerRadius: CreateWorkspaceFormStyle.cornerRadius
        ))
        .contentShape(.rect)
    }
}
