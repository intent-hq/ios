import SwiftUI

/// Archive and delete go through the workspace store, which removes the row. The page then leaves
/// for the workspace list; a failure keeps the page open and shows the server's message.
extension WorkspaceDetailView {
    func deleteWorkspace() { performWorkspaceAction(.delete) }

    func archiveWorkspace() { performWorkspaceAction(.archive) }

    private func performWorkspaceAction(_ action: WorkspaceAction) {
        let coordinator = coordinator
        Task {
            await presentation.perform(action, workspaceId: workspaceId, store: workspaceStore) {
                coordinator.onBackToWorkspaceList()
            }
        }
    }
}
