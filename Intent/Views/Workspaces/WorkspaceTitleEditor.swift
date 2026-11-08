import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceTitleEditor {
    var draft = ""
    private(set) var workspaceId: String?
    private(set) var isSaving = false
    private(set) var errorMessage: String?
    private var originalTitle = ""
    @ObservationIgnored private var requestID: UUID?

    var isEditing: Bool { workspaceId != nil }

    func begin(workspaceId: String, title: String) {
        guard !isEditing else { return }
        self.workspaceId = workspaceId
        originalTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = title
        errorMessage = nil
    }

    func cancel() {
        requestID = nil
        workspaceId = nil
        isSaving = false
        errorMessage = nil
        draft = ""
    }

    /// While the Mac connection is read-only the draft is kept and nothing is sent.
    func save(connection: ConnectionManagerRouting, store: WorkspaceStore, isReadOnly: Bool = false) async {
        guard let workspaceId, !isSaving, !isReadOnly else { return }
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title != originalTitle else { cancel(); return }
        guard !title.isEmpty else {
            errorMessage = "Enter a workspace name."
            return
        }
        let request = UUID()
        requestID = request
        isSaving = true
        errorMessage = nil
        do {
            let result = try await connection.request("workspace.update", params: ["workspaceId": workspaceId, "title": title])
            guard requestID == request else { return }
            guard let response = result as? [String: Any],
                  let workspace = response["workspace"] as? [String: Any],
                  workspace["id"] as? String == workspaceId,
                  workspace["title"] as? String == title else {
                isSaving = false
                errorMessage = "The name could not be saved. Please try again."
                return
            }
            store.applyConfirmedTitle(title, workspaceId: workspaceId)
            cancel()
        } catch {
            guard requestID == request else { return }
            isSaving = false
            errorMessage = error.localizedDescription
        }
    }
}
