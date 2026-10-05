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

    var body: some View {
        Button(action: onNext) {
            Text("Next")
                .interFont(Constants.Typography.bodySEmphasized)
                .padding(.horizontal, CreateWorkspaceFormStyle.controlPadding)
                .padding(.vertical, CreateWorkspaceFormStyle.controlVerticalPadding)
                .frame(minHeight: CreateWorkspaceFormStyle.controlHeight)
                .foregroundStyle(isDisabled ? CreateWorkspaceFormStyle.disabledForeground(for: colorScheme) : CreateWorkspaceFormStyle.primaryForeground)
                .background {
                    RoundedRectangle(cornerRadius: CreateWorkspaceFormStyle.cornerRadius)
                        .fill(isDisabled ? CreateWorkspaceFormStyle.disabledBackground(for: colorScheme) : CreateWorkspaceFormStyle.primary)
                        .modifier(WorkspaceControlShadow())
                }
        }
        .buttonStyle(IntentContentButtonStyle())
        .disabled(isDisabled)
        .accessibilityLabel("Next")
        .accessibilityIdentifier("creation.next")
    }
}
