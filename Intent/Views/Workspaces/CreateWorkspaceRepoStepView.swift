import SwiftUI

struct CreateWorkspaceRepoStepView: View {
    var store: GitHubRepoStore
    @Binding var selectedRepo: GitHubRepo?
    let onClose: () -> Void
    let onNext: () -> Void
    let onRepoChanged: () -> Void

    var body: some View {
        GitHubRepoPickerView(store: store, selectedRepo: $selectedRepo, usesCreationTypography: true)
            .navigationTitle("Select Repository")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: onClose)
                        .interFont(Constants.Typography.bodyS)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next", action: onNext)
                        .interFont(Constants.Typography.bodySEmphasized)
                        .disabled(selectedRepo == nil)
                }
            }
            .onChange(of: selectedRepo?.id) { _, _ in
                onRepoChanged()
            }
    }
}
