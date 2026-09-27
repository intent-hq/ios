import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceBrowserStoreTests {
    @Test func combinesSavedBrowsersWithRunningServersOnly() async throws {
        let fixture = try WorkspaceBrowserFixture()
        let manual = try fixture.store.create(workspaceId: "workspace", url: "https://example.com/docs")
        let other = try fixture.store.create(workspaceId: "other", url: "localhost:4000")
        fixture.fake.responseMap["script.list"] = ["scripts": [
            fixture.script(), fixture.script(), fixture.script(id: "stopped", status: "exited"),
            fixture.script(id: "other", workspaceId: "other"), fixture.script(id: "invalid", url: "file:///tmp"),
            ["id": "malformed"]
        ]]
        await fixture.store.refresh(workspaceId: "workspace")
        let browsers = fixture.store.browsers(workspaceId: "workspace")
        #expect(browsers.map(\.id) == ["script:preview", manual.id])
        #expect(browsers.first?.command == "npm run dev")
        #expect(fixture.store.browsers(workspaceId: "other") == [other])
        let params = try #require(fixture.fake.paramsForMethod("script.list").first)
        #expect(params["workspaceId"] as? String == "workspace")
        let subscription = try #require(fixture.fake.paramsForMethod("events.subscribe").first)
        #expect(subscription["eventTypes"] as? [String] == ["script:state", "script:changed"])
    }

    @Test func manualSessionsPersistPerBackendAndWorkspace() throws {
        let fixture = try WorkspaceBrowserFixture()
        let browser = try fixture.store.create(workspaceId: "workspace", url: "localhost:3000")
        let restored = WorkspaceBrowserStore(
            connection: fixture.fake, backendID: fixture.backendID, defaults: fixture.defaults
        )
        let otherBackend = WorkspaceBrowserStore(
            connection: fixture.fake, backendID: BackendID(UUID()), defaults: fixture.defaults
        )
        #expect(restored.browsers(workspaceId: "workspace") == [browser])
        #expect(restored.browsers(workspaceId: "other").isEmpty)
        #expect(otherBackend.browsers(workspaceId: "workspace").isEmpty)
        restored.remove(browser)
        let reopened = WorkspaceBrowserStore(
            connection: fixture.fake, backendID: fixture.backendID, defaults: fixture.defaults
        )
        #expect(reopened.browsers(workspaceId: "workspace").isEmpty)
        #expect(fixture.fake.requestLog.isEmpty)
    }

    @Test func unsavedBackendsNeverPersistBrowserSessions() throws {
        let fixture = try WorkspaceBrowserFixture()
        let ephemeral = WorkspaceBrowserStore(connection: fixture.fake, backendID: nil, defaults: fixture.defaults)
        _ = try ephemeral.create(workspaceId: "workspace", url: "localhost:3000")
        let reopened = WorkspaceBrowserStore(connection: fixture.fake, backendID: nil, defaults: fixture.defaults)
        #expect(reopened.browsers(workspaceId: "workspace").isEmpty)
    }

    @Test func invalidCreationDoesNotSaveABrowser() throws {
        let fixture = try WorkspaceBrowserFixture()
        #expect(throws: WorkspaceBrowserError.self) {
            try fixture.store.create(workspaceId: "workspace", url: "ftp://example.com")
        }
        #expect(fixture.store.browsers(workspaceId: "workspace").isEmpty)
    }

    @Test func removingADetectedBrowserHidesItWithoutStoppingTheServer() async throws {
        let fixture = try WorkspaceBrowserFixture()
        fixture.fake.responseMap["script.list"] = ["scripts": [fixture.script()]]
        await fixture.store.refresh(workspaceId: "workspace")
        let browser = try #require(fixture.store.browsers(workspaceId: "workspace").first)
        fixture.store.remove(browser)
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.browsers(workspaceId: "workspace").isEmpty)
        #expect(!fixture.fake.didCallMethod("script.stop"))
        #expect(!fixture.fake.didCallMethod("script.remove"))
        #expect(!fixture.fake.didCallMethod("terminal.kill"))
        let persistence = WorkspaceBrowserPersistence(backendID: fixture.backendID, defaults: fixture.defaults)
        #expect(persistence.load().isEmpty)
    }

    @Test func removalIsScopedToTheWorkspaceEvenWhenScriptIdsMatch() async throws {
        let fixture = try WorkspaceBrowserFixture()
        fixture.fake.responseMap["script.list"] = ["scripts": [fixture.script(), fixture.script(workspaceId: "other")]]
        await fixture.store.refresh(workspaceId: "workspace")
        await fixture.store.refresh(workspaceId: "other")
        let browser = try #require(fixture.store.browsers(workspaceId: "workspace").first)
        fixture.store.remove(browser)
        #expect(fixture.store.browsers(workspaceId: "workspace").isEmpty)
        #expect(fixture.store.browsers(workspaceId: "other").count == 1)
    }

    @Test func listFailureKeepsRowsAndErrorsBelongToTheirWorkspace() async throws {
        let fixture = try WorkspaceBrowserFixture()
        fixture.fake.responseMap["script.list"] = ["scripts": [fixture.script()]]
        await fixture.store.refresh(workspaceId: "workspace")
        fixture.fake.responseMap["script.list"] = ["unexpected": []]
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.browsers(workspaceId: "workspace").count == 1)
        #expect(fixture.store.errorMessage(workspaceId: "workspace") != nil)
        #expect(fixture.store.errorMessage(workspaceId: "other") == nil)
        fixture.fake.responseMap["script.list"] = ["scripts": []]
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.browsers(workspaceId: "workspace").isEmpty)
        #expect(fixture.store.errorMessage(workspaceId: "workspace") == nil)
    }

    @Test func scriptEventsRefreshDefinitionsAndDropStoppedServers() async throws {
        let fixture = try WorkspaceBrowserFixture()
        await fixture.store.refresh(workspaceId: "workspace")
        fixture.fake.responseMap["script.list"] = ["scripts": [fixture.script()]]
        fixture.event(type: "script:changed", action: "created")
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.browsers(workspaceId: "workspace").count == 1)
        fixture.fake.responseMap["script.list"] = ["scripts": [fixture.script(command: "pnpm dev")]]
        fixture.event(type: "script:changed")
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.browsers(workspaceId: "workspace").first?.command == "pnpm dev")
        fixture.fake.responseMap["script.list"] = ["scripts": []]
        fixture.event(status: "exited")
        #expect(fixture.store.browsers(workspaceId: "workspace").isEmpty)
        await fixture.store.refresh(workspaceId: "workspace")
    }

    @Test func irrelevantOrUnobservedWorkspaceEventsDoNotFetch() async throws {
        let fixture = try WorkspaceBrowserFixture()
        await fixture.store.refresh(workspaceId: "workspace")
        fixture.fake.clearRequestLog()
        fixture.event(type: "script:output")
        fixture.event(workspaceId: "other")
        fixture.event(subscriptionId: "unrelated-sub")
        try await expectNever("refresh for an irrelevant event") { fixture.fake.didCallMethod("script.list") }
    }

    @Test func reconnectionRefreshesObservedWorkspacesAndRetainsSavedBrowsers() async throws {
        let fixture = try WorkspaceBrowserFixture()
        let manual = try fixture.store.create(workspaceId: "workspace", url: "localhost:4000")
        fixture.fake.responseMap["script.list"] = ["scripts": [fixture.script()]]
        await fixture.store.refresh(workspaceId: "workspace")
        await fixture.store.refresh(workspaceId: "other")
        fixture.fake.connectionState = .disconnected
        #expect(!fixture.store.isConnected)
        #expect(fixture.store.browsers(workspaceId: "workspace") == [manual])
        fixture.fake.clearRequestLog()
        fixture.fake.responseMap["script.list"] = ["scripts": [fixture.script(url: "localhost:5000")]]
        fixture.fake.connectionState = .connected
        await fixture.store.refresh(workspaceId: "workspace")
        await fixture.store.refresh(workspaceId: "other")
        #expect(fixture.store.isConnected)
        #expect(fixture.store.browsers(workspaceId: "workspace").first?.url == "http://127.0.0.1:5000")
        #expect(fixture.fake.paramsForMethod("events.subscribe").count == 1)
        let workspaces = fixture.fake.paramsForMethod("script.list").compactMap { $0["workspaceId"] as? String }
        #expect(Set(workspaces) == ["workspace", "other"])
    }
}
