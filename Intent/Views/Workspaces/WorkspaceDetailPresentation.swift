import Combine
import Foundation
import Observation

/// What the workspace page is presenting over itself: confirmations, sheets, full-screen
/// resources, and the error left by a failed archive or delete.
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
    /// The browser made in the creation sheet, opened once the sheet has dismissed.
    var createdBrowser: WorkspaceBrowser?
    var terminalCreationRequest: UUID?
    /// The message of the last failed archive or delete, shown until dismissed.
    var actionError: String?

    /// Clears what belonged to the previous workspace when the page switches to another.
    func resetForWorkspaceChange() {
        terminalCreationRequest = nil
        selectedTerminal = nil
        selectedBrowser = nil
        createdBrowser = nil
        showNewBrowser = false
        showTransferWorkspace = false
    }

    /// Archives or deletes through the store. The page leaves as soon as the store removes the
    /// row, before the list refresh, and stays with an error when the server does not confirm.
    func perform(_ action: WorkspaceAction, workspaceId: String, store: WorkspaceStore, onLeave: @escaping () -> Void) async {
        let removal = store.removedWorkspaceIds.first { $0 == workspaceId }.sink { _ in onLeave() }
        defer { removal.cancel() }
        do {
            try await store.perform(action, workspaceId: workspaceId)
        } catch {
            AppLog.workspace.error("[WorkspaceDetail] \(action.method) failed: \(error)")
            actionError = error.localizedDescription
        }
    }
}
