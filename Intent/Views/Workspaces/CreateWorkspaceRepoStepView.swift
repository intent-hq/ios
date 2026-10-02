import SwiftUI

struct CreateWorkspaceRepoStepView: View {
    var store: GitHubRepoStore
    @Binding var selectedRepo: GitHubRepo?
    let onClose: () -> Void
    let onNext: () -> Void
    let onRepoChanged: () -> Void
    let onCreateRepository: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            CreateWorkspaceSelectionHeader(isNextDisabled: selectedRepo == nil, onLeadingAction: onClose, onNext: onNext)
            GitHubRepoPickerView(store: store, selectedRepo: $selectedRepo, onCreateRepository: onCreateRepository)
        }
        .background(CreateWorkspaceRepoStyle.background(for: colorScheme).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: selectedRepo?.id) { _, _ in
            onRepoChanged()
        }
    }
}

struct CreateWorkspaceSelectionHeader: View {
    enum LeadingControl {
        case close, back
    }

    var leadingControl: LeadingControl = .close
    let isNextDisabled: Bool
    let onLeadingAction: () -> Void
    let onNext: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .title3) private var iconSize = CreateWorkspaceRepoStyle.iconSize

    var body: some View {
        HStack {
            Button(action: onLeadingAction) {
                Image(leadingControl == .back ? .arrowLeft : .close)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .frame(minWidth: CreateWorkspaceFormStyle.controlHeight, minHeight: CreateWorkspaceFormStyle.controlHeight)
                    .contentShape(.rect)
            }
            .foregroundStyle(CreateWorkspaceRepoStyle.foreground(for: colorScheme))
            .accessibilityLabel(leadingControl == .back ? "Back" : "Close")
            .accessibilityIdentifier(leadingControl == .back ? "creation.branchBack" : "creation.close")
            Spacer()
            Button(action: onNext) {
                Text("Next")
                    .interFont(Constants.Typography.bodySEmphasized)
                    .padding(.horizontal, CreateWorkspaceFormStyle.controlPadding)
                    .padding(.vertical, CreateWorkspaceFormStyle.controlVerticalPadding)
                    .frame(minHeight: CreateWorkspaceFormStyle.controlHeight)
                    .foregroundStyle(CreateWorkspaceRepoStyle.foreground(for: colorScheme))
                    .background(CreateWorkspaceRepoStyle.card(for: colorScheme), in: .rect(
                        cornerRadius: CreateWorkspaceFormStyle.cornerRadius
                    ))
                    .opacity(isNextDisabled ? 0.5 : 1)
            }
            .disabled(isNextDisabled)
        }
        .buttonStyle(.plain)
        .padding(CreateWorkspaceFormStyle.pagePadding)
    }
}
