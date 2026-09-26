import SwiftUI

struct CreateWorkspaceFormHeader: View {
    let isCreateDisabled: Bool
    let isCreating: Bool
    let onBack: () -> Void
    let onCreate: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .title3) private var backIconSize: CGFloat = 24

    var body: some View {
        HStack {
            Button(action: onBack) {
                Label { Text("Back") } icon: {
                    Image(.arrowLeft)
                        .resizable()
                        .scaledToFit()
                        .frame(width: backIconSize, height: backIconSize)
                }
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .frame(minWidth: CreateWorkspaceFormStyle.controlHeight, minHeight: CreateWorkspaceFormStyle.controlHeight)
            .contentShape(.rect)
            .foregroundStyle(CreateWorkspaceFormStyle.foreground(for: colorScheme))
            .disabled(isCreating)
            .accessibilityIdentifier("creation.back")
            Spacer()
            Button(action: onCreate) {
                Text("Create")
                    .interFont(Constants.Typography.bodySEmphasized)
                    .padding(.horizontal, CreateWorkspaceFormStyle.controlPadding)
                    .padding(.vertical, CreateWorkspaceFormStyle.controlVerticalPadding)
                    .frame(minHeight: CreateWorkspaceFormStyle.controlHeight)
                    .foregroundStyle(CreateWorkspaceFormStyle.primaryForeground)
                    .background(CreateWorkspaceFormStyle.primary, in: .rect(
                        cornerRadius: CreateWorkspaceFormStyle.cornerRadius
                    ))
                    .opacity(isCreateDisabled ? 0.5 : 1)
            }
            .disabled(isCreateDisabled)
        }
        .buttonStyle(.plain)
        .padding(CreateWorkspaceFormStyle.pagePadding)
    }
}
