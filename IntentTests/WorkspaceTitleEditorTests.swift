import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceTitleEditorTests {
    @Test func saveUsesTheSelectedWorkspaceAndOnlyChangesItsTitle() async throws {
        let (connection, store, editor) = try fixture()
        editor.draft = "  Renamed workspace \n"

        await editor.save(connection: connection, store: store)

        let params = try #require(connection.paramsForMethod("workspace.update").first)
        #expect(Set(params.keys) == ["workspaceId", "title"])
        #expect(params["workspaceId"] as? String == "selected")
        #expect(params["title"] as? String == "Renamed workspace")
        #expect(store.workspaces.first?.title == "Renamed workspace")
        #expect(store.workspaces.first?.branch == "feature/original")
        #expect(!editor.isEditing)
        #expect(!editor.isSaving)
    }

    @Test func unchangedTitleClosesWithoutARequest() async throws {
        let (connection, store, editor) = try fixture()
        editor.draft = " Original "

        await editor.save(connection: connection, store: store)

        #expect(!editor.isEditing)
        #expect(!connection.didCallMethod("workspace.update"))
    }

    @Test func whitespaceOnlyTitleKeepsTheEditorOpen() async throws {
        let (connection, store, editor) = try fixture()
        editor.draft = " \n "

        await editor.save(connection: connection, store: store)

        #expect(editor.isEditing)
        #expect(editor.errorMessage != nil)
        #expect(store.workspaces.first?.title == "Original")
        #expect(!connection.didCallMethod("workspace.update"))
    }

    @Test func unnamedWorkspaceCanBeDismissedWithoutSavingThePlaceholder() async throws {
        let (connection, store, editor) = try fixture()
        editor.cancel()
        editor.begin(workspaceId: "selected", title: "")

        await editor.save(connection: connection, store: store)

        #expect(!editor.isEditing)
        #expect(!connection.didCallMethod("workspace.update"))
    }

    @Test func failurePreservesTheDraftAndAllowsRetry() async throws {
        let (connection, store, editor) = try fixture()
        editor.draft = "Renamed workspace"
        connection.errorMap["workspace.update"] = NSError(
            domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Disconnected"]
        )

        await editor.save(connection: connection, store: store)

        #expect(editor.isEditing)
        #expect(!editor.isSaving)
        #expect(editor.draft == "Renamed workspace")
        #expect(editor.errorMessage == "Disconnected")
        #expect(store.workspaces.first?.title == "Original")
        connection.errorMap.removeAll()
        await editor.save(connection: connection, store: store)
        #expect(!editor.isEditing)
        #expect(store.workspaces.first?.title == "Renamed workspace")
    }

    @Test(arguments: ["missing", "wrong-id", "wrong-title"])
    func unconfirmedResponseDoesNotPublishTheDraft(kind: String) async throws {
        let (connection, store, editor) = try fixture()
        editor.draft = "Renamed workspace"
        connection.responseMap["workspace.update"] = kind == "missing" ? [:] : [
            "workspace": [
                "id": kind == "wrong-id" ? "other" : "selected",
                "title": kind == "wrong-title" ? "Unexpected" : "Renamed workspace"
            ]
        ]

        await editor.save(connection: connection, store: store)

        #expect(editor.isEditing)
        #expect(!editor.isSaving)
        #expect(editor.draft == "Renamed workspace")
        #expect(editor.errorMessage != nil)
        #expect(store.workspaces.first?.title == "Original")
    }

    @Test func repeatedDoneSendsOneRequest() async throws {
        let (connection, store, editor) = try fixture()
        connection.pendingMethods.insert("workspace.update")
        editor.draft = "Renamed workspace"
        let save = Task { await editor.save(connection: connection, store: store) }
        try await connection.waitForPendingRequests("workspace.update")

        await editor.save(connection: connection, store: store)

        #expect(connection.paramsForMethod("workspace.update").count == 1)
        connection.resolvePending("workspace.update", with: response())
        await save.value
        #expect(!editor.isEditing)
    }

    @Test func leavingTheWorkspaceIgnoresItsLateSaveResponse() async throws {
        let (connection, store, editor) = try fixture()
        connection.pendingMethods.insert("workspace.update")
        editor.draft = "Renamed workspace"
        let save = Task { await editor.save(connection: connection, store: store) }
        try await connection.waitForPendingRequests("workspace.update")
        editor.cancel()
        editor.begin(workspaceId: "other", title: "Other")
        editor.draft = "Other draft"

        connection.resolvePending("workspace.update", with: response())
        await save.value

        #expect(editor.workspaceId == "other")
        #expect(editor.draft == "Other draft")
        #expect(editor.isEditing)
        #expect(!editor.isSaving)
        #expect(editor.errorMessage == nil)
    }

    @Test func staleListCannotUndoAConfirmedRename() async throws {
        let (connection, store, editor) = try fixture()
        connection.pendingMethods.insert("workspace.list")
        let refresh = Task { await store.fetchAll() }
        try await connection.waitForPendingRequests("workspace.list")
        editor.draft = "Renamed workspace"
        await editor.save(connection: connection, store: store)

        connection.resolvePending("workspace.list", with: ["workspaces": [["id": "selected", "title": "Old snapshot"]]])
        try await connection.waitForPendingRequests("workspace.list")
        #expect(store.workspaces.first?.title == "Renamed workspace")
        connection.resolvePending("workspace.list", with: ["workspaces": [["id": "selected", "title": "Renamed workspace"]]])
        await refresh.value
        #expect(store.workspaces.first?.title == "Renamed workspace")
    }

    private func fixture() throws -> (FakeConnectionManager, WorkspaceStore, WorkspaceTitleEditor) {
        let connection = FakeConnectionManager()
        connection.responseMap["workspace.update"] = response()
        connection.responseMap["workspace.list"] = ["workspaces": [
            ["id": "selected", "title": "Renamed workspace", "branch": "feature/original"]
        ]]
        let store = WorkspaceStore(connectionManager: connection)
        store.workspaces = [try #require(WorkspaceStore.parseWorkspace([
            "id": "selected", "title": "Original", "branch": "feature/original"
        ]))]
        let editor = WorkspaceTitleEditor()
        editor.begin(workspaceId: "selected", title: "Original")
        return (connection, store, editor)
    }

    private func response() -> [String: Any] {
        ["workspace": ["id": "selected", "title": "Renamed workspace"]]
    }
}
