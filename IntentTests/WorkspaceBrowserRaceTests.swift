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
}
