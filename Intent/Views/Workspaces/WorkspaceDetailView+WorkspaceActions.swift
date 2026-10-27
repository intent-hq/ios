import SwiftUI

/// Archive and delete leave the workspace, so the list reloads after the request.
extension WorkspaceDetailView {
    func deleteWorkspace() { changeWorkspace("workspace.delete") }

    func archiveWorkspace() { changeWorkspace("workspace.archive") }

    func changeWorkspace(_ method: String) {
        Task {
            do {
                _ = try await session.connection.request(method, params: ["workspaceId": workspaceId])
                coordinator.onBackToWorkspaceList()
                await workspaceStore.fetchAll()
            } catch {
                AppLog.workspace.error("[WorkspaceDetail] \(method) failed: \(error)")
            }
        }
    }
}
