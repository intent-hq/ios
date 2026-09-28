import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceBrowserTabTests {
    @Test func registryTabsAppearWithoutScriptsAndStayWorkspaceScoped() async throws {
        let fixture = try WorkspaceBrowserFixture()
        let tab = fixture.tab()
        fixture.fake.responseMap["browser.listTabs"] = [
            "tabs": [tab, tab, fixture.tab(workspaceId: "other"), fixture.tab(id: "invalid", url: "file:///tmp")]
        ]
        await fixture.store.refresh(workspaceId: "workspace")
        let browser = try #require(fixture.store.browsers(workspaceId: "workspace").first)
        #expect(fixture.store.browsers(workspaceId: "workspace").count == 1)
        #expect(browser.id == "tab:agent-preview")
        #expect(browser.url == "http://127.0.0.1:3000/docs")
        #expect(browser.command == nil)
        #expect(!browser.isSavedSession)
        #expect(fixture.store.browsers(workspaceId: "other").isEmpty)
        let params = try #require(fixture.fake.paramsForMethod("browser.listTabs").first)
        #expect(params["workspaceId"] as? String == "workspace")
        #expect(try fixture.store.open(workspaceId: "workspace", url: browser.url) == browser)
        let persistence = WorkspaceBrowserPersistence(backendID: fixture.backendID, defaults: fixture.defaults)
        #expect(persistence.load().isEmpty)
        fixture.store.remove(browser)
        #expect(fixture.store.browsers(workspaceId: "workspace") == [browser])
        #expect(!fixture.fake.didCallMethod("browser.closeTab"))
        #expect(!fixture.fake.didCallMethod("browser.removeTab"))
    }

    @Test func matchingScriptAndTabBecomeOneRowKeepingTheCommandAndTabPath() async throws {
        let fixture = try WorkspaceBrowserFixture()
        fixture.fake.responseMap["script.list"] = ["scripts": [fixture.script()]]
        fixture.fake.responseMap["browser.listTabs"] = [
            "tabs": [fixture.tab(url: "http://127.0.0.1:49152/docs?q=1", requestedURL: "http://daemon.localhost:3000/docs?q=1")]
        ]
        await fixture.store.refresh(workspaceId: "workspace")
        let browser = try #require(fixture.store.browsers(workspaceId: "workspace").first)
        #expect(fixture.store.browsers(workspaceId: "workspace").count == 1)
        #expect(browser.id == "script:preview")
        #expect(browser.command == "npm run dev")
        #expect(browser.url == "http://127.0.0.1:3000/docs?q=1")
        #expect(try fixture.store.open(workspaceId: "workspace", url: browser.url) == browser)
    }

    @Test func distinctTabPathsAreNotLostWhenMergingWithAServer() async throws {
        let fixture = try WorkspaceBrowserFixture()
        fixture.fake.responseMap["script.list"] = ["scripts": [fixture.script()]]
        fixture.fake.responseMap["browser.listTabs"] = [
            "tabs": [fixture.tab(), fixture.tab(id: "settings", url: "localhost:3000/settings")]
        ]
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.browsers(workspaceId: "workspace").map(\.url) == [
            "http://127.0.0.1:3000/docs", "http://127.0.0.1:3000/settings"
        ])
        fixture.fake.responseMap["script.list"] = ["scripts": [fixture.script(url: "localhost:3000/api")]]
        await fixture.store.refresh(workspaceId: "workspace")
        let expectedCount = 3
        #expect(fixture.store.browsers(workspaceId: "workspace").count == expectedCount)
    }

    @Test func olderDaemonsWithoutTabRegistryStillDiscoverScripts() async throws {
        let fixture = try WorkspaceBrowserFixture()
        fixture.fake.responseMap["script.list"] = ["scripts": [fixture.script()]]
        let methodNotFound = -32_601
        fixture.fake.errorMap["browser.listTabs"] = NSError(domain: "WebSocket", code: methodNotFound)
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.browsers(workspaceId: "workspace").first?.command == "npm run dev")
        #expect(fixture.store.errorMessage(workspaceId: "workspace") == nil)
    }

    @Test func failedDiscoveryDoesNotPreventTheOtherSourceFromUpdating() async throws {
        let fixture = try WorkspaceBrowserFixture()
        fixture.fake.responseMap["browser.listTabs"] = ["tabs": [fixture.tab()]]
        fixture.fake.errorMap["script.list"] = WorkspaceBrowserError.invalidResponse
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.browsers(workspaceId: "workspace").first?.id == "tab:agent-preview")
        #expect(fixture.store.errorMessage(workspaceId: "workspace") != nil)
        fixture.fake.errorMap["script.list"] = nil
        fixture.fake.responseMap["script.list"] = ["scripts": [fixture.script(url: "localhost:4000")]]
        fixture.fake.errorMap["browser.listTabs"] = WorkspaceBrowserError.invalidResponse
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.browsers(workspaceId: "workspace").map(\.id) == ["script:preview", "tab:agent-preview"])
        #expect(fixture.store.errorMessage(workspaceId: "other") == nil)
    }

    @Test func tabEventsApplyImmediatelyAndOnlyToTheMatchingWorkspace() async throws {
        let fixture = try WorkspaceBrowserFixture()
        await fixture.store.refresh(workspaceId: "workspace")
        let tab = fixture.tab()
        fixture.fake.responseMap["browser.listTabs"] = ["tabs": [tab]]
        fixture.tabEvent(tab: tab)
        #expect(fixture.store.browsers(workspaceId: "workspace").first?.url == "http://127.0.0.1:3000/docs")
        await fixture.store.refresh(workspaceId: "workspace")
        let updated = fixture.tab(url: "localhost:3000/settings")
        fixture.fake.responseMap["browser.listTabs"] = ["tabs": [updated]]
        fixture.tabEvent(tab: updated, type: "browser:tab-updated")
        #expect(fixture.store.browsers(workspaceId: "workspace").first?.url == "http://127.0.0.1:3000/settings")
        fixture.tabEvent(tab: updated, type: "browser:tab-closed", workspaceId: "other")
        fixture.tabEvent(tab: fixture.tab(workspaceId: "other"), type: "browser:tab-closed")
        fixture.tabEvent(tab: updated, type: "browser:tab-closed", subscriptionId: "unrelated")
        #expect(fixture.store.browsers(workspaceId: "workspace").count == 1)
        fixture.fake.responseMap["browser.listTabs"] = ["tabs": []]
        fixture.tabEvent(tab: updated, type: "browser:tab-closed")
        #expect(fixture.store.browsers(workspaceId: "workspace").isEmpty)
        await fixture.store.refresh(workspaceId: "workspace")
    }

    @Test func registryTabsAreNotRestoredFromManualPersistence() async throws {
        let fixture = try WorkspaceBrowserFixture()
        fixture.fake.responseMap["browser.listTabs"] = ["tabs": [fixture.tab()]]
        await fixture.store.refresh(workspaceId: "workspace")
        let restored = WorkspaceBrowserStore(connection: fixture.fake, backendID: fixture.backendID, defaults: fixture.defaults)
        #expect(restored.browsers(workspaceId: "workspace").isEmpty)
        fixture.fake.connectionState = .disconnected
        #expect(fixture.store.browsers(workspaceId: "workspace").isEmpty)
        fixture.fake.connectionState = .connected
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.browsers(workspaceId: "workspace").count == 1)
    }

    @Test func lateDiscoveryHidesASavedDuplicateWithoutDeletingItsSession() async throws {
        let fixture = try WorkspaceBrowserFixture()
        let saved = try fixture.store.open(workspaceId: "workspace", url: "localhost:3000/docs?q=1")
        let otherPath = try fixture.store.open(workspaceId: "workspace", url: "localhost:3000/other")
        fixture.fake.pendingMethods.insert("browser.listTabs")
        let refresh = Task { await fixture.store.refresh(workspaceId: "workspace") }
        try await fixture.fake.waitForPendingRequests("browser.listTabs")
        #expect(fixture.store.browsers(workspaceId: "workspace") == [saved, otherPath])
        fixture.fake.resolvePending("browser.listTabs", with: ["tabs": [fixture.tab(url: saved.url)]])
        await refresh.value
        let discovered = try #require(fixture.store.browsers(workspaceId: "workspace").first)
        #expect(discovered.id == "tab:agent-preview")
        #expect(fixture.store.browsers(workspaceId: "workspace").map(\.id) == [discovered.id, otherPath.id])
        #expect(try fixture.store.open(workspaceId: "workspace", url: saved.url) == discovered)
        let persistence = WorkspaceBrowserPersistence(backendID: fixture.backendID, defaults: fixture.defaults)
        #expect(persistence.load() == [saved, otherPath])
        fixture.fake.pendingMethods.remove("browser.listTabs")
        fixture.fake.responseMap["script.list"] = ["scripts": [fixture.script(url: saved.url)]]
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.browsers(workspaceId: "workspace").first?.command == "npm run dev")
        #expect(fixture.store.browsers(workspaceId: "workspace").count == 2)
        fixture.fake.responseMap["script.list"] = ["scripts": []]
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.browsers(workspaceId: "workspace") == [saved, otherPath])
    }
}
