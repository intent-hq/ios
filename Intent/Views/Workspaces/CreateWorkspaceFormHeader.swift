import SwiftUI

struct CreateWorkspaceFormHeader: View {
    let isCreateDisabled: Bool
    let isCreating: Bool
    let onBack: () -> Void
    let onCreate: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack {
            Button("Back", systemImage: "arrow.left", action: onBack)
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
