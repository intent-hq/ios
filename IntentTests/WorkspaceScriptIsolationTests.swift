import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceScriptIsolationTests {
    @Test func cancelWhileStatusIsPendingPreventsLaunchAndLatePresentation() async throws {
        let fixture = WorkspaceScriptFixture()
        let script = try await fixture.idleScript()
        fixture.fake.pendingMethods.insert("script.status")
        let launch = Task { await fixture.store.launch(script) }
        try await fixture.fake.waitForPendingRequests("script.status")
        fixture.store.cancelPendingLaunch(workspaceId: "workspace")
        fixture.fake.resolvePending("script.status", with: fixture.runtime(status: "running", url: "localhost:3000"))
        await launch.value
        fixture.event(url: "localhost:3000")
        #expect(!fixture.store.isLaunching(script))
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
        #expect(!fixture.fake.didCallMethod("script.start"))
    }

    @Test func cancelWhileStartIsPendingCannotReopenAfterItsReply() async throws {
        let fixture = WorkspaceScriptFixture()
        let script = try await fixture.idleScript()
        fixture.startReplies(status: "running", url: "localhost:3000")
        fixture.fake.pendingMethods.insert("script.start")
        let launch = Task { await fixture.store.launch(script) }
        try await fixture.fake.waitForPendingRequests("script.start")
        fixture.store.cancelPendingLaunch(workspaceId: "workspace")
        fixture.fake.resolvePending("script.start", with: ["ok": true])
        await launch.value
        fixture.event(url: "localhost:3000")
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
        #expect(!fixture.store.isLaunching(script))
    }

    @Test func cancelClearsAnUnconsumedPresentationAndPermitsExplicitReopen() async throws {
        let fixture = WorkspaceScriptFixture()
        let script = try await fixture.idleScript()
        fixture.fake.responseMap["script.status"] = fixture.runtime(status: "running", url: "localhost:3000")
        await fixture.store.launch(script)
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") != nil)
        fixture.store.cancelPendingLaunch(workspaceId: "workspace")
        #expect(fixture.store.takeBrowserToOpen(workspaceId: "workspace") == nil)
        await fixture.store.launch(script)
        #expect(fixture.store.takeBrowserToOpen(workspaceId: "workspace") != nil)
        #expect(!fixture.fake.didCallMethod("script.start"))
    }

    @Test func sameScriptIDsInDifferentWorkspacesKeepSeparateLaunches() async throws {
        let fixture = WorkspaceScriptFixture()
        await fixture.load([fixture.definition(), fixture.definition(workspaceId: "other")])
        await fixture.store.refresh(workspaceId: "other")
        let first = try #require(fixture.store.scripts(workspaceId: "workspace").first)
        let second = try #require(fixture.store.scripts(workspaceId: "other").first)
        fixture.startReplies()
        await fixture.store.launch(first)
        fixture.startReplies()
        await fixture.store.launch(second)
        fixture.store.cancelPendingLaunch(workspaceId: "workspace")
        fixture.event(url: "localhost:3000")
        fixture.event(workspaceId: "other", url: "localhost:5000")
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
        let browser = try #require(fixture.store.takeBrowserToOpen(workspaceId: "other"))
        #expect(browser.workspaceId == "other")
        #expect(browser.url == "http://127.0.0.1:5000")
        #expect(fixture.fake.paramsForMethod("script.start").map { $0["workspaceId"] as? String } == ["workspace", "other"])
    }

    @Test func windowsUseUniqueSubscriptionsAndOnlyLaunchingWindowPresents() async throws {
        let fixture = WorkspaceScriptFixture()
        let second = WorkspaceScriptStore(connection: fixture.fake)
        fixture.fake.responseQueueMap["events.subscribe"] = [["subscriptionId": "window-one"], ["subscriptionId": "window-two"]]
        await fixture.load([fixture.definition()])
        await second.refresh(workspaceId: "workspace")
        let groups = fixture.fake.paramsForMethod("events.subscribe").compactMap { $0["replaceGroup"] as? String }
        #expect(groups.count == 2)
        #expect(Set(groups).count == 2)
        let script = try #require(fixture.store.scripts(workspaceId: "workspace").first)
        fixture.startReplies()
        await fixture.store.launch(script)
        fixture.event(url: "localhost:3000", subscriptionId: "wrong-subscription")
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
        fixture.event(url: "localhost:3000", subscriptionId: "window-two")
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
        #expect(second.browserToOpen(workspaceId: "workspace") == nil)
        fixture.event(url: "localhost:3000", subscriptionId: "window-one")
        #expect(fixture.store.takeBrowserToOpen(workspaceId: "workspace") != nil)
        #expect(second.browserToOpen(workspaceId: "workspace") == nil)
    }

    @Test func differentBackendsCannotRouteEventsToEachOther() async throws {
        let first = WorkspaceScriptFixture()
        let second = WorkspaceScriptFixture()
        let script = try await first.idleScript()
        _ = try await second.idleScript()
        first.startReplies()
        await first.store.launch(script)
        second.event(url: "localhost:3000")
        #expect(first.store.browserToOpen(workspaceId: "workspace") == nil)
        #expect(second.store.browserToOpen(workspaceId: "workspace") == nil)
        first.event(url: "localhost:5000")
        #expect(first.store.takeBrowserToOpen(workspaceId: "workspace")?.url == "http://127.0.0.1:5000")
    }

    @Test func reconnectCancelsPendingLaunchAndRejectsPreviousStartReply() async throws {
        let fixture = WorkspaceScriptFixture()
        let script = try await fixture.idleScript()
        fixture.startReplies(status: "running", url: "localhost:3000")
        fixture.fake.pendingMethods.insert("script.start")
        let launch = Task { await fixture.store.launch(script) }
        try await fixture.fake.waitForPendingRequests("script.start")
        fixture.fake.connectionState = .disconnected
        #expect(!fixture.store.isConnected)
        #expect(!fixture.store.isLaunching(script))
        fixture.fake.resolvePending("script.start", with: ["ok": true])
        fixture.fake.responseMap["events.subscribe"] = ["subscriptionId": "new-sub"]
        fixture.fake.responseMap["script.list"] = ["scripts": [fixture.definition(status: "running", url: "localhost:5000")]]
        fixture.fake.connectionState = .connected
        await launch.value
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.isConnected)
        #expect(fixture.store.scripts(workspaceId: "workspace").first?.detectedURL == "localhost:5000")
        fixture.event(url: "localhost:3000")
        #expect(fixture.store.scripts(workspaceId: "workspace").first?.detectedURL == "localhost:5000")
        fixture.event(url: "localhost:6000", subscriptionId: "new-sub")
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
        #expect(fixture.store.errorMessage(workspaceId: "workspace") == nil)
    }

    @Test func reconnectDuringSubscriptionDoesNotStartCancelledIntent() async throws {
        let fixture = WorkspaceScriptFixture()
        let script = WorkspaceScript(id: "preview", workspaceId: "workspace", name: "Preview", command: "npm run dev")
        fixture.fake.pendingMethods.insert("events.subscribe")
        let launch = Task { await fixture.store.launch(script) }
        try await fixture.fake.waitForPendingRequests("events.subscribe")
        fixture.fake.connectionState = .disconnected
        fixture.fake.resolvePending("events.subscribe", with: ["subscriptionId": "old-sub"])
        fixture.fake.pendingMethods.remove("events.subscribe")
        fixture.fake.responseMap["events.subscribe"] = ["subscriptionId": "new-sub"]
        fixture.fake.responseMap["script.list"] = ["scripts": [fixture.definition()]]
        fixture.fake.connectionState = .connected
        await launch.value
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(!fixture.fake.didCallMethod("script.start"))
        #expect(!fixture.store.isLaunching(script))
        fixture.event(url: "localhost:3000", subscriptionId: "old-sub")
        #expect(fixture.store.scripts(workspaceId: "workspace").first?.status == "idle")
    }

    @Test func failedSubscriptionDoesNotStartScript() async {
        let fixture = WorkspaceScriptFixture()
        fixture.fake.responseMap["events.subscribe"] = ["unexpected": "missing id"]
        let script = WorkspaceScript(id: "preview", workspaceId: "workspace", name: "Preview", command: "npm run dev")
        await fixture.store.launch(script)
        #expect(fixture.store.errorMessage(workspaceId: "workspace") != nil)
        #expect(!fixture.store.isLaunching(script))
        #expect(!fixture.fake.didCallMethod("script.start"))
    }

    @Test func disconnectClearsAReadyPresentation() async throws {
        let fixture = WorkspaceScriptFixture()
        let script = try await fixture.idleScript()
        fixture.fake.responseMap["script.status"] = fixture.runtime(status: "running", url: "localhost:3000")
        await fixture.store.launch(script)
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") != nil)
        fixture.fake.connectionState = .disconnected
        #expect(fixture.store.takeBrowserToOpen(workspaceId: "workspace") == nil)
        await fixture.store.launch(script)
        #expect(!fixture.store.isLaunching(script))
    }
}
