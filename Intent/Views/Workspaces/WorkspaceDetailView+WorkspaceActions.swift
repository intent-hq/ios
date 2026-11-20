import SwiftUI

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
