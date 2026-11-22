import Foundation
@testable import Intent
import Testing

@MainActor
struct NativeBrowserNavigationTests {
    private static let defaultWindow = UUID()

    private func fixture() -> (FakeConnectionManager, NativeBrowserNavigation) {
        let connection = FakeConnectionManager()
        connection.connectionState = .connected
        connection.responseMap["browser.syncTabs"] = ["drop": [String]()]
        connection.responseMap["workspace.list"] = ["workspaces": [["id": "workspace"], ["id": "deleted"]]]
        let navigation = NativeBrowserNavigation(connection: connection)
        navigation.setWindow(Self.defaultWindow, active: true)
        return (connection, navigation)
    }

    private func request(_ actions: [[String: Any]], agent: String = "agent", workspace: String = "workspace") -> [String: Any] {
        ["workspaceId": workspace, "agentId": agent, "actions": actions]
    }

    private func errorCode(_ response: [String: Any]) -> String? {
        (response["results"] as? [[String: Any]])?.last?["errorCode"] as? String
    }

    @Test func openingReportsOwnershipAndAcceptanceBeforePresentation() async throws {
        let (connection, navigation) = fixture()
        let window = UUID()
        navigation.setWindow(window, active: true)
        let reply = await navigation.execute(request([["action": "openTab", "url": "http://daemon.localhost:3000/preview"]]))
        #expect(reply["success"] as? Bool == true)
        let tab = try #require(navigation.tabs.first)
        #expect(tab.ownerAgentId == "agent")
        #expect(tab.url == "http://127.0.0.1:3000/preview")
        #expect(navigation.presentation(window: window)?.id == tab.id)
        #expect(!tab.displayed)
        let reports = try #require(connection.paramsForMethod("browser.syncTabs").last?["tabs"] as? [[String: Any]])
        #expect(reports.first?["navigationOnly"] as? Bool == true)
        #expect(reports.first?["ownerAgentId"] as? String == "agent")
        navigation.setDisplayed(tab.id, true)
        try await waitUntil("displayed registry report") {
            let rows = connection.paramsForMethod("browser.syncTabs").last?["tabs"] as? [[String: Any]]
            return rows?.first?["displayed"] as? Bool == true
        }
    }

    @Test func hiddenOpenDoesNotPresentAndShowUsesOneForegroundWindow() async throws {
        let (_, navigation) = fixture()
        let window = UUID()
        navigation.setWindow(window, active: true)
        _ = await navigation.execute(request([["action": "openTab", "url": "localhost:3000", "visible": false]]))
        let tab = try #require(navigation.tabs.first)
        #expect(navigation.presentedID == nil)
        let second = UUID()
        navigation.setWindow(second, active: true)
        let reply = await navigation.execute(request([["action": "showTab", "tabId": tab.id]]))
        #expect(reply["success"] as? Bool == true)
        #expect(navigation.presentation(window: second)?.id == tab.id)
        #expect(navigation.presentation(window: window) == nil)
        navigation.setWindow(second, active: false)
        navigation.setWindow(window, active: false)
        navigation.setWindow(Self.defaultWindow, active: false)
        let unavailable = await navigation.execute(request([["action": "focusTab", "tabId": tab.id]]))
        #expect(errorCode(unavailable) == "browser-navigation-unavailable")
    }

    @Test func repeatedAndRedirectedURLsReuseTabWithoutNavigatingItBack() async throws {
        let (_, navigation) = fixture()
        let action: [String: Any] = ["action": "openTab", "url": "http://daemon.localhost:3000"]
        _ = await navigation.execute(request([action]))
        let id = try #require(navigation.tabs.first?.id)
        _ = await navigation.execute(request([["action": "openTab", "url": "http://localhost:3000/"]]))
        #expect(navigation.tabs.count == 1)
        navigation.pageChanged(id, url: "http://127.0.0.1:3000/home", title: "Home")
        _ = await navigation.execute(request([action]))
        _ = await navigation.execute(request([["action": "openTab", "url": "localhost:3000/home"]]))
        #expect(navigation.tabs.count == 1)
        #expect(navigation.tabs.first?.id == id)
        #expect(navigation.tabs.first?.url == "http://127.0.0.1:3000/home")
        let window = try #require(navigation.presenterID)
        navigation.dismiss(window: window)
        _ = await navigation.execute(request([action]))
        #expect(navigation.presentation(window: window)?.url == "http://127.0.0.1:3000/home")
    }

    @Test func userTabsAreReusedWithoutClaimAndCannotBeChangedByAgent() async throws {
        let (_, navigation) = fixture()
        let user = WorkspaceBrowser(id: "browser:user", workspaceId: "workspace", title: "User", url: "http://127.0.0.1:3000", command: nil)
        navigation.presentUserBrowser(user)
        let id = try #require(navigation.tabs.first?.id)
        _ = await navigation.execute(request([["action": "openTab", "url": "localhost:3000"]]))
        #expect(navigation.tabs.count == 1)
        #expect(navigation.tabs.first?.ownerAgentId == nil)
        for name in ["navigate", "closeTab"] {
            let reply = await navigation.execute(request([["action": name, "tabId": id, "url": "localhost:4000"]]))
            #expect(errorCode(reply) == "not-owner")
        }
        #expect(navigation.tabs.first?.url == user.url)
        #expect(navigation.tabs.count == 1)
    }

    @Test func otherAgentsAndOtherWorkspacesCannotOperateTab() async throws {
        let (_, navigation) = fixture()
        _ = await navigation.execute(request([["action": "openTab", "url": "localhost:3000"]]))
        let id = try #require(navigation.tabs.first?.id)
        for name in ["navigate", "closeTab", "showTab", "focusTab"] {
            let action: [String: Any] = ["action": name, "tabId": id, "url": "localhost:4000"]
            #expect(errorCode(await navigation.execute(request([action], agent: "other"))) == "not-owner")
            #expect(errorCode(await navigation.execute(request([action], workspace: "other"))) == "tab-not-found")
        }
        #expect(errorCode(await navigation.execute(request([["action": "openTab", "url": "localhost:3000"]], agent: "other"))) == "not-owner")
        #expect(navigation.tabs.count == 1)
    }

    @Test func unsupportedBatchHasNoSideEffects() async {
        let (connection, navigation) = fixture()
        let reply = await navigation.execute(request([
            ["action": "openTab", "url": "localhost:3000"], ["action": "screenshot"]
        ]))
        #expect(errorCode(reply) == "browser-automation-unavailable")
        #expect(navigation.tabs.isEmpty)
        #expect(connection.paramsForMethod("browser.syncTabs").isEmpty)
    }

    @Test func navigateAndCloseKeepIdentityAndReportRemoval() async throws {
        let (connection, navigation) = fixture()
        _ = await navigation.execute(request([["action": "openTab", "url": "localhost:3000"]]))
        let id = try #require(navigation.tabs.first?.id)
        _ = await navigation.execute(request([["action": "navigate", "tabId": id, "url": "localhost:3000/new"]]))
        #expect(navigation.tabs.first?.id == id)
        #expect(navigation.tabs.first?.ownerAgentId == "agent")
        #expect(navigation.tabs.first?.url == "http://127.0.0.1:3000/new")
        _ = await navigation.execute(request([["action": "closeTab", "tabId": id]]))
        #expect(navigation.tabs.isEmpty)
        #expect(navigation.presentedID == nil)
        let report = connection.paramsForMethod("browser.syncTabs").last?["tabs"] as? [[String: Any]]
        #expect(report?.isEmpty == true)
    }

    @Test func failedAndDroppedRegistryReportsNeverClaimSuccess() async {
        let (connection, navigation) = fixture()
        connection.errorMap["browser.syncTabs"] = WorkspaceBrowserError.invalidResponse
        let failed = await navigation.execute(request([["action": "openTab", "url": "localhost:3000"]]))
        #expect(failed["success"] as? Bool == false)
        connection.errorMap["browser.syncTabs"] = nil
        let id = navigation.tabs.first?.id ?? ""
        connection.responseMap["browser.syncTabs"] = ["drop": [id]]
        let dropped = await navigation.execute(request([["action": "focusTab", "tabId": id]]))
        #expect(errorCode(dropped) == "tab-not-found")
        #expect(navigation.tabs.isEmpty)
    }

    @Test func disconnectDuringReportStopsRemainingBatchAndReconnectRetainsOwners() async throws {
        let (connection, navigation) = fixture()
        connection.pendingMethods = ["browser.syncTabs"]
        let task = Task {
            let result = await navigation.execute(request([
                ["action": "openTab", "url": "localhost:3000"], ["action": "openTab", "url": "localhost:4000"]
            ]))
            return result["success"] as? Bool
        }
        try await waitUntil("pending registry report") { connection.didCallMethod("browser.syncTabs") }
        connection.connectionState = .disconnected
        connection.resolvePending("browser.syncTabs", with: ["drop": [String]()])
        #expect(await task.value == false)
        #expect(navigation.tabs.count == 1)
        connection.pendingMethods = []
        connection.connectionState = .connected
        try await waitUntil("reconnect sync") { connection.paramsForMethod("browser.syncTabs").count == 2 }
        #expect(navigation.tabs.first?.ownerAgentId == "agent")
    }

    @Test func restoredTabsKeepIDsAndOwnersButDoNotInventPresentation() async throws {
        let (connection, _) = fixture()
        let suite = "NativeBrowserTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = BackendID(UUID())
        let navigation = NativeBrowserNavigation(connection: connection, backendID: backend, defaults: defaults)
        _ = await navigation.execute(request([["action": "openTab", "url": "localhost:3000", "visible": false]]))
        let original = try #require(navigation.tabs.first)
        let restored = NativeBrowserNavigation(connection: connection, backendID: backend, defaults: defaults)
        #expect(restored.tabs.first?.id == original.id)
        #expect(restored.tabs.first?.ownerAgentId == "agent")
        #expect(restored.tabs.first?.displayed == false)
        #expect(restored.presentedID == nil)
        let otherBackend = NativeBrowserNavigation(connection: connection, backendID: BackendID(UUID()), defaults: defaults)
        #expect(otherBackend.tabs.isEmpty)
    }

    @Test func deletedOfflineWorkspaceCannotPoisonRestoredSnapshot() async throws {
        let (connection, _) = fixture()
        let suite = "NativeBrowserDeletedTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = BackendID(UUID())
        let original = NativeBrowserNavigation(connection: connection, backendID: backend, defaults: defaults)
        _ = await original.execute(request([["action": "openTab", "url": "localhost:3000", "visible": false]], workspace: "deleted"))
        #expect(original.tabs.count == 1)
        connection.responseMap["workspace.list"] = ["workspaces": [["id": "workspace"]]]
        let restored = NativeBrowserNavigation(connection: connection, backendID: backend, defaults: defaults)
        let reply = await restored.execute(request([["action": "openTab", "url": "localhost:4000", "visible": false]]))
        #expect(reply["success"] as? Bool == true)
        #expect(restored.tabs.map(\.workspaceId) == ["workspace"])
        let rows = try #require(connection.paramsForMethod("browser.syncTabs").last?["tabs"] as? [[String: Any]])
        #expect(rows.allSatisfy { $0["workspaceId"] as? String == "workspace" })
    }

    @Test func authoritativeOwnershipAndClosureEventsUpdateNativeRegistry() async throws {
        let (connection, navigation) = fixture()
        _ = await navigation.execute(request([["action": "openTab", "url": "localhost:3000"]]))
        let id = try #require(navigation.tabs.first?.id)
        connection.deliverEvent(method: "event", params: [
            "type": "browser:tab-updated", "data": ["tab": ["tabId": id, "workspaceId": "workspace", "ownerAgentId": "other"]]
        ])
        #expect(navigation.tabs.first?.ownerAgentId == "other")
        #expect(errorCode(await navigation.execute(request([["action": "closeTab", "tabId": id]]))) == "not-owner")
        connection.deliverEvent(method: "event", params: [
            "type": "browser:tab-closed", "data": ["tab": ["tabId": id, "workspaceId": "workspace"]]
        ])
        #expect(navigation.tabs.isEmpty)
        #expect(navigation.presentedID == nil)
    }

    @Test func reverseRequestsAreNotMistakenForNumericReplies() {
        for id in ["\"reverse-1\"", "1"] {
            let frame = ConnectionManager.parseInboundFrame("{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"browser.exec\",\"params\":{\"actions\":[]}}")
            guard case let .request(_, method, _) = frame else { Issue.record("Expected reverse request"); return }
            #expect(method == "browser.exec")
        }
        guard case .response = ConnectionManager.parseInboundFrame("{\"id\":1,\"result\":{}}") else {
            Issue.record("Ordinary response changed"); return
        }
    }

    @Test func onlyReadyRPCConnectionsAdvertiseNavigation() throws {
        let ordinary = try #require(PairingClientIdentity.parameters()["capabilities"] as? [String: Bool])
        #expect(ordinary["browserNavigation"] == false)
        #expect(ordinary["browserExec"] == false)
        let ready = try #require(PairingClientIdentity.parameters(browserNavigation: true)["capabilities"] as? [String: Bool])
        #expect(ready["browserNavigation"] == true)
        #expect(ready["browserExec"] == false)
    }
}
