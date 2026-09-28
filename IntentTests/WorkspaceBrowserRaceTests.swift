import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceBrowserRaceTests {
    @Test func concurrentRefreshesShareTheSubscriptionAndListRequest() async throws {
        let fixture = try WorkspaceBrowserFixture()
        fixture.fake.pendingMethods.insert("events.subscribe")
        fixture.fake.pendingMethods.insert("script.list")
        let first = Task { await fixture.store.refresh(workspaceId: "workspace") }
        let second = Task { await fixture.store.refresh(workspaceId: "workspace") }
        try await fixture.fake.waitForPendingRequests("events.subscribe")
        fixture.fake.resolvePending("events.subscribe", with: ["subscriptionId": "browser-sub"])
        try await fixture.fake.waitForPendingRequests("script.list")
        fixture.fake.resolvePending("script.list", with: ["scripts": [fixture.script()]])
        await first.value
        await second.value
        #expect(fixture.fake.paramsForMethod("events.subscribe").count == 1)
        #expect(fixture.fake.paramsForMethod("script.list").count == 1)
    }

    @Test func eventStormInvalidatesTheOldListAndCoalescesOneTrailingFetch() async throws {
        let fixture = try WorkspaceBrowserFixture()
        await fixture.store.refresh(workspaceId: "workspace")
        fixture.fake.clearRequestLog()
        fixture.fake.pendingMethods.insert("script.list")
        let refresh = Task { await fixture.store.refresh(workspaceId: "workspace") }
        try await fixture.fake.waitForPendingRequests("script.list")
        let eventCount = 20
        for _ in 0..<eventCount { fixture.event() }
        fixture.fake.resolvePending("script.list", with: ["scripts": [fixture.script(url: "localhost:3000")]])
        try await fixture.fake.waitForPendingRequests("script.list")
        #expect(fixture.store.browsers(workspaceId: "workspace").isEmpty)
        fixture.fake.resolvePending("script.list", with: ["scripts": [fixture.script(url: "localhost:5000")]])
        await refresh.value
        #expect(fixture.fake.paramsForMethod("script.list").count == 2)
        #expect(fixture.store.browsers(workspaceId: "workspace").first?.url == "http://127.0.0.1:5000")
    }

    @Test func scriptRemovalDuringRefreshCannotResurrectTheRow() async throws {
        let fixture = try WorkspaceBrowserFixture()
        fixture.fake.responseMap["script.list"] = ["scripts": [fixture.script()]]
        await fixture.store.refresh(workspaceId: "workspace")
        fixture.fake.pendingMethods.insert("script.list")
        let refresh = Task { await fixture.store.refresh(workspaceId: "workspace") }
        try await fixture.fake.waitForPendingRequests("script.list")
        fixture.event(type: "script:changed", action: "removed")
        #expect(fixture.store.browsers(workspaceId: "workspace").isEmpty)
        fixture.fake.resolvePending("script.list", with: ["scripts": [fixture.script()]])
        try await fixture.fake.waitForPendingRequests("script.list")
        #expect(fixture.store.browsers(workspaceId: "workspace").isEmpty)
        fixture.fake.resolvePending("script.list", with: ["scripts": []])
        await refresh.value
        #expect(fixture.store.browsers(workspaceId: "workspace").isEmpty)
    }

    @Test func localEditsDuringRefreshArePreserved() async throws {
        let fixture = try WorkspaceBrowserFixture()
        fixture.fake.responseMap["script.list"] = ["scripts": [fixture.script()]]
        await fixture.store.refresh(workspaceId: "workspace")
        let detected = try #require(fixture.store.browsers(workspaceId: "workspace").first)
        let removed = try fixture.store.create(workspaceId: "workspace", url: "localhost:8000")
        fixture.fake.pendingMethods.insert("script.list")
        let refresh = Task { await fixture.store.refresh(workspaceId: "workspace") }
        try await fixture.fake.waitForPendingRequests("script.list")
        fixture.store.remove(detected)
        fixture.store.remove(removed)
        let added = try fixture.store.create(workspaceId: "workspace", url: "localhost:9000")
        fixture.fake.resolvePending("script.list", with: ["scripts": [fixture.script()]])
        await refresh.value
        #expect(fixture.store.browsers(workspaceId: "workspace") == [added])
    }

    @Test func reconnectRejectsAnOldListResponse() async throws {
        let fixture = try WorkspaceBrowserFixture()
        fixture.fake.pendingMethods.insert("script.list")
        let oldRefresh = Task { await fixture.store.refresh(workspaceId: "workspace") }
        try await fixture.fake.waitForPendingRequests("script.list")
        fixture.fake.connectionState = .disconnected
        fixture.fake.responseMap["script.list"] = ["scripts": [fixture.script(url: "localhost:5000")]]
        fixture.fake.pendingMethods.remove("script.list")
        fixture.fake.connectionState = .connected
        fixture.fake.resolvePending("script.list", with: ["scripts": [fixture.script(url: "localhost:3000")]])
        await oldRefresh.value
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.browsers(workspaceId: "workspace").first?.url == "http://127.0.0.1:5000")
        #expect(fixture.store.errorMessage(workspaceId: "workspace") == nil)
    }

    @Test func reconnectRejectsAnOldSubscriptionResponse() async throws {
        let fixture = try WorkspaceBrowserFixture()
        fixture.fake.pendingMethods.insert("events.subscribe")
        let oldRefresh = Task { await fixture.store.refresh(workspaceId: "workspace") }
        try await fixture.fake.waitForPendingRequests("events.subscribe")
        fixture.fake.connectionState = .disconnected
        fixture.fake.pendingMethods.remove("events.subscribe")
        fixture.fake.responseMap["events.subscribe"] = ["subscriptionId": "new-sub"]
        fixture.fake.connectionState = .connected
        fixture.fake.resolvePending("events.subscribe", with: ["subscriptionId": "old-sub"])
        await oldRefresh.value
        await fixture.store.refresh(workspaceId: "workspace")
        fixture.fake.responseMap["script.list"] = ["scripts": [fixture.script()]]
        fixture.event(subscriptionId: "new-sub")
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.browsers(workspaceId: "workspace").count == 1)
        #expect(fixture.store.errorMessage(workspaceId: "workspace") == nil)
        #expect(fixture.fake.paramsForMethod("events.subscribe").count == 2)
    }

    @Test func oldFailuresCannotReplaceTheReconnectedWorkspacesError() async throws {
        let fixture = try WorkspaceBrowserFixture()
        fixture.fake.pendingMethods.insert("script.list")
        let oldRefresh = Task { await fixture.store.refresh(workspaceId: "workspace") }
        try await fixture.fake.waitForPendingRequests("script.list")
        fixture.fake.connectionState = .disconnected
        fixture.fake.pendingMethods.remove("script.list")
        fixture.fake.connectionState = .connected
        fixture.fake.failPending("script.list", with: WorkspaceBrowserError.invalidResponse)
        await oldRefresh.value
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.errorMessage(workspaceId: "workspace") == nil)
    }

    @Test func tabCloseDuringAListCannotResurrectTheClosedTab() async throws {
        let fixture = try WorkspaceBrowserFixture()
        let tab = fixture.tab()
        fixture.fake.responseMap["browser.listTabs"] = ["tabs": [tab]]
        await fixture.store.refresh(workspaceId: "workspace")
        fixture.fake.pendingMethods.insert("browser.listTabs")
        let refresh = Task { await fixture.store.refresh(workspaceId: "workspace") }
        try await fixture.fake.waitForPendingRequests("browser.listTabs")
        fixture.tabEvent(tab: tab, type: "browser:tab-closed")
        #expect(fixture.store.browsers(workspaceId: "workspace").isEmpty)
        fixture.fake.resolvePending("browser.listTabs", with: ["tabs": [tab]])
        try await fixture.fake.waitForPendingRequests("browser.listTabs")
        #expect(fixture.store.browsers(workspaceId: "workspace").isEmpty)
        fixture.fake.resolvePending("browser.listTabs", with: ["tabs": []])
        await refresh.value
        #expect(fixture.store.browsers(workspaceId: "workspace").isEmpty)
    }

    @Test func tabUpdateStormCoalescesAndPreservesManualChanges() async throws {
        let fixture = try WorkspaceBrowserFixture()
        fixture.fake.pendingMethods.insert("browser.listTabs")
        let refresh = Task { await fixture.store.refresh(workspaceId: "workspace") }
        try await fixture.fake.waitForPendingRequests("browser.listTabs")
        let tab = fixture.tab(url: "localhost:3000/settings?q=2")
        let eventCount = 20
        for _ in 0..<eventCount { fixture.tabEvent(tab: tab, type: "browser:tab-updated") }
        let manual = try fixture.store.open(workspaceId: "workspace", url: "localhost:4000/docs")
        fixture.fake.resolvePending("browser.listTabs", with: ["tabs": []])
        try await fixture.fake.waitForPendingRequests("browser.listTabs")
        #expect(fixture.store.browsers(workspaceId: "workspace").first?.url == "http://127.0.0.1:3000/settings?q=2")
        fixture.fake.resolvePending("browser.listTabs", with: ["tabs": [tab]])
        await refresh.value
        #expect(fixture.store.browsers(workspaceId: "workspace").last == manual)
        #expect(fixture.fake.paramsForMethod("browser.listTabs").count == 2)
    }

    @Test func reconnectRejectsThePreviousConnectionsTabSnapshot() async throws {
        let fixture = try WorkspaceBrowserFixture()
        fixture.fake.pendingMethods.insert("browser.listTabs")
        let oldRefresh = Task { await fixture.store.refresh(workspaceId: "workspace") }
        try await fixture.fake.waitForPendingRequests("browser.listTabs")
        fixture.fake.connectionState = .disconnected
        fixture.fake.pendingMethods.remove("browser.listTabs")
        fixture.fake.responseMap["browser.listTabs"] = ["tabs": [fixture.tab(url: "localhost:3000/new")]]
        fixture.fake.connectionState = .connected
        fixture.fake.resolvePending("browser.listTabs", with: ["tabs": [fixture.tab(url: "localhost:3000/old")]])
        await oldRefresh.value
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.browsers(workspaceId: "workspace").first?.url == "http://127.0.0.1:3000/new")
        #expect(fixture.store.errorMessage(workspaceId: "workspace") == nil)
    }

    @Test func oldTabEventsAreIgnoredWhileTheNewSubscriptionIsPending() async throws {
        let fixture = try WorkspaceBrowserFixture()
        await fixture.store.refresh(workspaceId: "workspace")
        fixture.fake.connectionState = .disconnected
        fixture.fake.pendingMethods.insert("events.subscribe")
        fixture.fake.connectionState = .connected
        try await fixture.fake.waitForPendingRequests("events.subscribe")
        fixture.tabEvent(tab: fixture.tab())
        #expect(fixture.store.browsers(workspaceId: "workspace").isEmpty)
        fixture.fake.resolvePending("events.subscribe", with: ["subscriptionId": "new-sub"])
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.browsers(workspaceId: "workspace").isEmpty)
    }
}
