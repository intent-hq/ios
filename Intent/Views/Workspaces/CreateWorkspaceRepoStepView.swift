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
        GitHubRepoPickerView(
            store: store,
            selectedRepo: $selectedRepo,
            onCreateRepository: onCreateRepository,
            onNext: onNext,
            onClose: onClose
        )
        .background(CreateWorkspaceRepoStyle.background(for: colorScheme).ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: selectedRepo?.id) { _, _ in
            onRepoChanged()
        }
    }
}

struct CreateWorkspaceNextButton: View {
    let isDisabled: Bool
    let onNext: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .body) private var iconSize = CreateWorkspaceRepoStyle.iconSize

    var body: some View {
        Button(action: onNext) {
            HStack(spacing: CreateWorkspaceFormStyle.rowSpacing) {
                Text("Next")
                    .interFont(Constants.Typography.bodySEmphasized)
                Image(.arrowRight)
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, CreateWorkspaceFormStyle.controlPadding)
            .padding(.vertical, CreateWorkspaceFormStyle.controlVerticalPadding)
            .frame(minHeight: CreateWorkspaceFormStyle.controlHeight)
            .foregroundStyle(isDisabled ? CreateWorkspaceRepoStyle.foreground(for: colorScheme) : CreateWorkspaceFormStyle.primaryForeground)
            .background(isDisabled ? CreateWorkspaceRepoStyle.card(for: colorScheme) : CreateWorkspaceFormStyle.primary, in: .rect(
                cornerRadius: CreateWorkspaceFormStyle.cornerRadius
            ))
            .opacity(isDisabled ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel("Next")
        .accessibilityIdentifier("creation.next")
    }
}
