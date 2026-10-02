import SwiftUI

struct CreateWorkspaceNavigationButton: View {
    enum Control {
        case close, back
    }

    var control: Control = .back
    var identifier = "creation.branchBack"
    let onAction: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var iconSize = CreateWorkspaceRepoStyle.iconSize

    var body: some View {
        Button(action: onAction) {
            Image(control == .back ? .arrowLeft : .close)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .padding(CreateWorkspaceFormStyle.controlVerticalPadding)
                .frame(minWidth: CreateWorkspaceFormStyle.controlHeight, minHeight: CreateWorkspaceFormStyle.controlHeight)
                .foregroundStyle(CreateWorkspaceFormStyle.foreground(for: colorScheme))
                .background { WorkspaceControlSurface() }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(control == .back ? "Back" : "Close")
        .accessibilityIdentifier(identifier)
    }
}

struct CreateWorkspaceSubmitButton: View {
    let isDisabled: Bool
    let onCreate: () -> Void
    @ScaledMetric(relativeTo: .body) private var iconSize = CreateWorkspaceRepoStyle.iconSize

    var body: some View {
        Button(action: onCreate) {
            HStack(spacing: CreateWorkspaceFormStyle.rowSpacing) {
                Text("Create")
                    .interFont(Constants.Typography.bodySEmphasized)
                Image(.addIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .accessibilityHidden(true)
            }
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
        .accessibilityLabel("Create")
        .accessibilityIdentifier("creation.create")
    }
}
