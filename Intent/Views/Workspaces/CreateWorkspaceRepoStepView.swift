import SwiftUI

struct CreateWorkspaceRepoStepView: View {
    var store: GitHubRepoStore
    @Binding var selectedRepo: GitHubRepo?
    let colorScheme: ColorScheme
    let onClose: () -> Void
    let onNext: () -> Void
    let onRepoChanged: () -> Void

    var body: some View {
        GitHubRepoPickerView(store: store, selectedRepo: $selectedRepo)
            .navigationTitle("Select Repository")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .foregroundStyle(Theme.foreground(for: colorScheme))
                    }
                    .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Next", action: onNext)
                        .disabled(selectedRepo == nil)
                }
            }
            .onChange(of: selectedRepo?.id) { _, _ in
                onRepoChanged()
            }
    }
}