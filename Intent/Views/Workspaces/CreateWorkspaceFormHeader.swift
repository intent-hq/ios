import SwiftUI

struct CreateWorkspaceFormHeader: View {
    let isCreating: Bool
    let onBack: () -> Void
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
        }
        .buttonStyle(.plain)
        .padding(CreateWorkspaceFormStyle.pagePadding)
    }
}

struct CreateWorkspaceSubmitButton: View {
    let isDisabled: Bool
    let onCreate: () -> Void

    var body: some View {
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
                .opacity(isDisabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityIdentifier("creation.create")
    }
}
