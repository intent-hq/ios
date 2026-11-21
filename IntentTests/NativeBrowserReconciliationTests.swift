import Foundation
@testable import Intent
import Testing

@MainActor
struct NativeBrowserReconciliationTests {
    private func connection() -> FakeConnectionManager {
        let connection = FakeConnectionManager()
        connection.connectionState = .connected
        connection.responseMap["browser.syncTabs"] = ["drop": [String]()]
        return connection
    }

    private func open(_ navigation: NativeBrowserNavigation, workspace: String) async -> Bool {
        let result = await navigation.execute([
            "workspaceId": workspace, "agentId": "owner",
            "actions": [["action": "openTab", "url": "localhost:3000", "visible": false]]
        ])
        return result["success"] as? Bool == true
    }

    @Test func restoredLaterPageTabsSurviveAndOnlyMissingWorkspacesArePruned() async throws {
        let suite = "NativeBrowserPages-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = BackendID(UUID())
        let originalConnection = connection()
        originalConnection.responseMap["workspace.list"] = ["workspaces": [["id": "later"], ["id": "deleted"]]]
        let original = NativeBrowserNavigation(connection: originalConnection, backendID: backend, defaults: defaults)
        #expect(await open(original, workspace: "later"))
        #expect(await open(original, workspace: "deleted"))
        let originalID = try #require(original.tabs.first?.id)

        let reconnected = connection()
        reconnected.responseQueueMap["workspace.list"] = [
            ["workspaces": (0..<200).map { ["id": "first-\($0)"] }, "nextToken": "second"],
            ["workspaces": [[String: Any]](), "nextToken": "last"],
            ["workspaces": [["id": "later"]], "nextToken": NSNull()]
        ]
        let restored = NativeBrowserNavigation(connection: reconnected, backendID: backend, defaults: defaults)
        #expect(await open(restored, workspace: "later"))
        #expect(restored.tabs.map(\.id) == [originalID])
        #expect(restored.tabs.first?.ownerAgentId == "owner")
        let pages = reconnected.paramsForMethod("workspace.list")
        #expect(pages.map { $0["nextToken"] as? String } == [nil, "second", "last"])
        #expect(pages.allSatisfy { $0["includeArchived"] as? Bool == true && $0["limit"] as? Int == PagedReads.workspacePageLimit })
        let rows = try #require(reconnected.paramsForMethod("browser.syncTabs").last?["tabs"] as? [[String: Any]])
        #expect(rows.compactMap { $0["tabId"] as? String } == [originalID])
    }

    @Test(arguments: ["malformed", "repeated-token", "failure", "disconnected"])
    func incompleteWalkNeverPrunesOrPublishesPartialSnapshot(outcome: String) async throws {
        let connection = connection()
        connection.pendingMethods = ["workspace.list"]
        let navigation = NativeBrowserNavigation(connection: connection)
        let opening = Task { await open(navigation, workspace: "later") }
        try await connection.waitForPendingRequests("workspace.list")
        connection.resolvePending("workspace.list", with: ["workspaces": [["id": "first"]], "nextToken": "next"])
        try await connection.waitForPendingRequests("workspace.list")
        #expect(navigation.tabs.map(\.workspaceId) == ["later"])
        #expect(!connection.didCallMethod("browser.syncTabs"))
        switch outcome {
        case "malformed": connection.resolvePending("workspace.list", with: ["unexpected": true])
        case "repeated-token":
            connection.resolvePending("workspace.list", with: ["workspaces": [["id": "first"]], "nextToken": "next"])
        case "disconnected":
            connection.connectionState = .disconnected
            connection.resolvePending("workspace.list", with: ["workspaces": [["id": "first"]]])
        default: connection.failPending("workspace.list", with: URLError(.networkConnectionLost))
        }
        #expect(await opening.value == false)
        #expect(navigation.tabs.map(\.workspaceId) == ["later"])
        #expect(!connection.didCallMethod("browser.syncTabs"))
    }
}
