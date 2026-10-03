import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceActionTests {
    @Test func refreshIncludesArchivedRowsWithoutShowingThemByDefault() async throws {
        let (fake, store) = try fixture()
        fake.responseMap["workspace.list"] = ["workspaces": [
            ["id": "active", "title": "Active"],
            ["id": "archived", "title": "Archived", "status": "Archived"]
        ]]
        let model = WorkspaceListViewModel(workspaceStore: store)

        await store.fetchAll()

        #expect(fake.paramsForMethod("workspace.list").first?["includeArchived"] as? Bool == true)
        #expect(Set(store.workspaces.map(\.id)) == ["active", "archived"])
        #expect(model.filteredWorkspaces.map(\.id) == ["active"])
        model.showArchived = true
        await store.fetchAll()
        #expect(Set(model.filteredWorkspaces.map(\.id)) == ["active", "archived"])
    }

    @Test(arguments: [WorkspaceAction.archive, .delete])
    func successUsesSelectedWorkspaceAndRefreshes(_ action: WorkspaceAction) async throws {
        let (fake, store) = try fixture()
        fake.responseMap[action.method] = successResponse(action)
        fake.responseMap["workspace.list"] = ["workspaces": [["id": "other", "title": "Updated"]]]

        try await store.perform(action, workspaceId: "selected")

        let params = try #require(fake.paramsForMethod(action.method).first)
        #expect(params["workspaceId"] as? String == "selected")
        #expect(fake.paramsForMethod(action.method).count == 1)
        #expect(store.workspaces.map(\.id) == ["other"])
        #expect(store.workspaces.first?.title == "Updated")
        #expect(store.updatingWorkspaceIDs.isEmpty)
    }

    @Test(arguments: [WorkspaceAction.archive, .delete])
    func failureRetainsWorkspaceAndAllowsRetry(_ action: WorkspaceAction) async throws {
        let (fake, store) = try fixture()
        fake.errorMap[action.method] = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Disconnected"])
        do {
            try await store.perform(action, workspaceId: "selected")
            Issue.record("Expected the request error")
        } catch {
            #expect(error.localizedDescription == "Disconnected")
        }
        #expect(store.workspaces.map(\.id) == ["selected", "other"])
        #expect(store.updatingWorkspaceIDs.isEmpty)
        #expect(!fake.didCallMethod("workspace.list"))

        fake.errorMap.removeAll()
        fake.responseMap[action.method] = successResponse(action)
        fake.responseMap["workspace.list"] = ["workspaces": [["id": "other", "title": "Other"]]]
        try await store.perform(action, workspaceId: "selected")
        #expect(store.workspaces.map(\.id) == ["other"])
    }

    @Test(arguments: [WorkspaceAction.archive, .delete])
    func unconfirmedResponseKeepsTheWorkspace(_ action: WorkspaceAction) async throws {
        let (fake, store) = try fixture()
        fake.responseMap[action.method] = ["success": false]
        await #expect(throws: (any Error).self) { try await store.perform(action, workspaceId: "selected") }
        #expect(store.workspaces.map(\.id) == ["selected", "other"])
        #expect(!fake.didCallMethod("workspace.list"))
        #expect(store.updatingWorkspaceIDs.isEmpty)
    }

    @Test func duplicateActionsAreIgnoredWhileWaitingForTheServer() async throws {
        let (fake, store) = try fixture()
        fake.pendingMethods.insert("workspace.archive")
        fake.responseMap["workspace.list"] = ["workspaces": [["id": "other", "title": "Other"]]]
        let archive = Task { try await store.perform(.archive, workspaceId: "selected") }
        try await fake.waitForPendingRequests("workspace.archive")
        #expect(store.updatingWorkspaceIDs == ["selected"])
        #expect(store.workspaces.count == 2)
        try await store.perform(.archive, workspaceId: "selected")
        try await store.perform(.delete, workspaceId: "selected")
        #expect(fake.paramsForMethod("workspace.archive").count == 1)
        #expect(!fake.didCallMethod("workspace.delete"))
        fake.resolvePending("workspace.archive", with: successResponse(.archive))
        try await archive.value
        #expect(store.updatingWorkspaceIDs.isEmpty)
    }

    @Test func staleRefreshCannotRestoreDeletedWorkspace() async throws {
        let (fake, store) = try fixture()
        fake.pendingMethods.insert("workspace.list")
        let refresh = Task { await store.fetchAll() }
        try await fake.waitForPendingRequests("workspace.list")
        fake.responseMap["workspace.delete"] = successResponse(.delete)
        let deletion = Task { try await store.perform(.delete, workspaceId: "selected") }
        try await waitUntil("selected workspace removed") { store.workspaces.count == 1 }
        fake.resolvePending("workspace.list", with: ["workspaces": [["id": "selected", "title": "Stale"]]])
        try await fake.waitForPendingRequests("workspace.list")
        #expect(store.workspaces.map(\.id) == ["other"])
        fake.resolvePending("workspace.list", with: ["workspaces": [["id": "other", "title": "Fresh"]]])
        await refresh.value
        try await deletion.value
        #expect(store.workspaces.map(\.title) == ["Fresh"])
    }

    private func fixture() throws -> (FakeConnectionManager, WorkspaceStore) {
        let fake = FakeConnectionManager()
        let store = WorkspaceStore(connectionManager: fake)
        store.workspaces = try ["selected", "other"].map { id in
            try #require(WorkspaceStore.parseWorkspace(["id": id, "title": id]))
        }
        return (fake, store)
    }

    private func successResponse(_ action: WorkspaceAction) -> [String: Any] {
        action == .delete ? ["success": true] : ["workspace": ["id": "selected", "status": "Archived"]]
    }
}
