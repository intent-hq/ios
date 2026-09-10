import SwiftUI

struct CreateWorkspaceRepoStepView: View {
    var store: GitHubRepoStore
    @Binding var selectedRepo: GitHubRepo?
    let onClose: () -> Void
    let onNext: () -> Void
    let onRepoChanged: () -> Void

    var body: some View {
        GitHubRepoPickerView(store: store, selectedRepo: $selectedRepo)
            .navigationTitle("Select Repository")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel, action: onClose)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next", action: onNext)
                        .disabled(selectedRepo == nil)
                }
            }
            .onChange(of: selectedRepo?.id) { _, _ in
                onRepoChanged()
            }
    }
}