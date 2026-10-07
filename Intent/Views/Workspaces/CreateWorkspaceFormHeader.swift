import SwiftUI

struct CreateWorkspaceNavigationButton: View {
    enum Control {
        case close, back
    }

    var control: Control = .back
    var identifier = "creation.branchBack"
    let onAction: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var iconSize = CreateWorkspaceRepoStyle.iconSize

    var body: some View {
        Button(action: onAction) {
            Image(control == .back ? .arrowLeft : .close)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .padding(CreateWorkspaceFormStyle.controlVerticalPadding)
                .frame(minWidth: CreateWorkspaceFormStyle.controlHeight, minHeight: CreateWorkspaceFormStyle.controlHeight)
                .foregroundStyle(isEnabled
                    ? CreateWorkspaceFormStyle.foreground(for: colorScheme)
                    : CreateWorkspaceFormStyle.disabledForeground(for: colorScheme))
                .background { WorkspaceControlSurface() }
        }
        .buttonStyle(IntentContentButtonStyle())
        .accessibilityLabel(control == .back ? "Back" : "Close")
        .accessibilityIdentifier(identifier)
    }
}

struct CreateWorkspaceSubmitButton: View {
    private enum Motion {
        static let duration = 0.35
        static let bounce = 0.18
        static let labelScale = 0.8
    }

    let isCreating: Bool
    let isDisabled: Bool
    var title: LocalizedStringKey = "Create"
    let onCreate: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var iconSize = CreateWorkspaceRepoStyle.iconSize
    @State private var labelSize: CGSize = .zero

    private var diameter: CGFloat {
        max(CreateWorkspaceFormStyle.controlHeight, iconSize + CreateWorkspaceFormStyle.controlVerticalPadding * 2)
    }

    var body: some View {
        Button(action: onCreate) {
            morphingLabel
        }
        .buttonStyle(IntentContentButtonStyle())
        .disabled(isDisabled || isCreating)
        .accessibilityLabel(isCreating ? "Creating workspace" : title)
        .accessibilityIdentifier("creation.create")
    }

    private var morphingLabel: some View {
        ZStack {
            readyLabel
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { labelSize = $0 }
                .scaleEffect(isCreating && !reduceMotion ? Motion.labelScale : 1)
                .opacity(isCreating ? 0 : 1)
            if isCreating {
                IntentLoadingIndicator(size: iconSize, label: "Creating workspace")
                    .environment(\.colorScheme, .light)
                    .transition(.opacity)
            }
        }
        .frame(width: isCreating ? diameter : (labelSize.width > 0 ? labelSize.width : nil))
        .frame(height: max(diameter, labelSize.height))
        .foregroundStyle(isDisabled && !isCreating
            ? CreateWorkspaceFormStyle.disabledForeground(for: colorScheme)
            : CreateWorkspaceFormStyle.primaryForeground)
        .background {
            RoundedRectangle(cornerRadius: isCreating ? diameter / 2 : CreateWorkspaceFormStyle.cornerRadius)
                .fill(isDisabled && !isCreating
                    ? CreateWorkspaceFormStyle.disabledBackground(for: colorScheme)
                    : CreateWorkspaceFormStyle.primary)
                .modifier(WorkspaceControlShadow())
        }
        .accessibilityHidden(true)
        .animation(reduceMotion ? nil : .spring(duration: Motion.duration, bounce: Motion.bounce), value: isCreating)
    }

    private var readyLabel: some View {
        HStack(spacing: CreateWorkspaceFormStyle.rowSpacing) {
            Image(.addIcon)
                .resizable()
                .scaledToFit()
                .frame(width: iconSize, height: iconSize)
                .accessibilityHidden(true)
            Text(title)
                .interFont(Constants.Typography.bodySEmphasized)
        }
        .padding(.horizontal, CreateWorkspaceFormStyle.controlPadding)
        .padding(.vertical, CreateWorkspaceFormStyle.controlVerticalPadding)
    }
}
