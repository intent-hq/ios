import Combine
import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceDetailPresentation {
    var showDeleteConfirmation = false
    var showArchiveConfirmation = false
    var showSpecialistPicker = false
    var showNewBrowser = false
    var showTransferWorkspace = false
    var selectedTerminal: MobileTerminal?
    var selectedBrowser: WorkspaceBrowser?
    var createdBrowser: WorkspaceBrowser?
    var terminalCreationRequest: UUID?
    var shareRequest: ShareWorkspaceRequest?
    var actionError: String?

    func resetForWorkspaceChange() {
        terminalCreationRequest = nil
        selectedTerminal = nil
        selectedBrowser = nil
        createdBrowser = nil
        showNewBrowser = false
        showTransferWorkspace = false
        shareRequest = nil
    }

    func perform(_ action: WorkspaceAction, workspaceId: String, store: WorkspaceStore, onLeave: @escaping () -> Void) async {
        let removal = store.removedWorkspaceIds.first { $0 == workspaceId }.sink { _ in onLeave() }
        defer { removal.cancel() }
        do {
            try await store.perform(action, workspaceId: workspaceId)
        } catch {
            AppLog.workspace.error("[WorkspaceDetail] \(action.method) failed: \(error)")
            actionError = DiagnosticErrorOwnership.alertMessage(for: error)
        }
    }
}
