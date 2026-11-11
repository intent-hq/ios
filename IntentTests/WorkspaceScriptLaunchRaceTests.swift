import Foundation
@testable import Intent
import Testing

@MainActor
struct WorkspaceScriptLaunchRaceTests {
    @Test func startsFinishingAfterSuspensionAreRetiredAndCanBeLaunchedAgain() async throws {
        for succeeds in [true, false] {
            let fixture = WorkspaceScriptFixture()
            let script = try await fixture.idleScript()
            fixture.fake.responseMap["script.status"] = fixture.runtime(status: "idle")
            fixture.fake.pendingMethods.insert("script.start")
            let oldLaunch = Task { await fixture.store.launch(script) }
            try await fixture.fake.waitForPendingRequests("script.start")
            fixture.store.suspendObservation()
            #expect(!fixture.store.isLaunching(script))
            if succeeds {
                fixture.fake.resolvePending("script.start", with: ["ok": true])
            } else {
                fixture.fake.failPending("script.start", with: NSError(domain: "old start", code: 1))
            }
            await oldLaunch.value
            #expect(fixture.store.startTasks.isEmpty)
            #expect(fixture.store.errorMessage(workspaceId: "workspace") == nil)
            #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
            fixture.store.resumeObservation()
            let newLaunch = Task { await fixture.store.launch(script) }
            try await fixture.fake.waitForPendingRequests("script.start")
            #expect(fixture.fake.paramsForMethod("script.start").count == 2)
            fixture.fake.resolvePending("script.start", with: ["ok": true])
            await newLaunch.value
            #expect(fixture.store.startTasks.isEmpty)
        }
    }

    @Test func oldStartCleanupCannotRemoveNewStartAfterReconnect() async throws {
        let fake = StartReplyHoldingConnection()
        let fixture = WorkspaceScriptFixture(fake: fake)
        let script = try await fixture.idleScript()
        fixture.fake.responseMap["script.status"] = fixture.runtime(status: "idle")
        fixture.fake.pendingMethods.insert("script.start")
        defer { fake.startReplyGate.open() }
        let oldLaunch = Task { await fixture.store.launch(script) }
        try await fixture.fake.waitForPendingRequests("script.start")
        // Hold a delivered reply across reconnect: the normal fake removes
        // parked requests on cancellation, which cannot create this overlap.
        fixture.fake.resolvePending("script.start", with: ["ok": true])
        try await waitUntil("first start reply held before cleanup") { fake.holdsFirstStartReply }
        fixture.store.suspendObservation()
        fixture.store.resumeObservation()
        fixture.fake.connectionState = .disconnected
        fixture.fake.connectionState = .connected
        await fixture.store.refresh(workspaceId: "workspace")
        let newLaunch = Task { await fixture.store.launch(script) }
        try await fixture.fake.waitForPendingRequests("script.start")
        #expect(fixture.fake.paramsForMethod("script.start").count == 2)
        let key = WorkspaceScriptStore.ScriptKey(workspaceId: script.workspaceId, scriptId: script.id)
        let newStartId = try #require(fixture.store.startTasks[key]?.id)
        fake.startReplyGate.open()
        await oldLaunch.value
        #expect(fixture.store.startTasks[key]?.id == newStartId)
        #expect(fixture.store.isLaunching(script))
        fixture.fake.resolvePending("script.start", with: ["ok": true])
        await newLaunch.value
        #expect(fixture.store.startTasks.isEmpty)
    }

    @Test func concurrentRefreshesShareSubscriptionAndList() async throws {
        let fixture = WorkspaceScriptFixture()
        fixture.fake.pendingMethods = ["events.subscribe", "script.list"]
        let first = Task { await fixture.store.refresh(workspaceId: "workspace") }
        let second = Task { await fixture.store.refresh(workspaceId: "workspace") }
        try await fixture.fake.waitForPendingRequests("events.subscribe")
        fixture.fake.resolvePending("events.subscribe", with: ["subscriptionId": "scripts-sub"])
        try await fixture.fake.waitForPendingRequests("script.list")
        fixture.fake.resolvePending("script.list", with: ["scripts": [fixture.definition()]])
        await first.value
        await second.value
        #expect(fixture.fake.paramsForMethod("events.subscribe").count == 1)
        #expect(fixture.fake.paramsForMethod("script.list").count == 1)
    }

    @Test func duplicateTapsShareIntentBeforeSubscriptionAndBeforeStartReply() async throws {
        let fixture = WorkspaceScriptFixture()
        let script = WorkspaceScript(id: "preview", workspaceId: "workspace", name: "Preview", command: "npm run dev")
        fixture.fake.pendingMethods = ["events.subscribe", "script.start"]
        fixture.startReplies()
        let first = Task { await fixture.store.launch(script) }
        try await fixture.fake.waitForPendingRequests("events.subscribe")
        await fixture.store.launch(script)
        #expect(fixture.store.isLaunching(script))
        #expect(!fixture.fake.didCallMethod("script.start"))
        fixture.fake.resolvePending("events.subscribe", with: ["subscriptionId": "scripts-sub"])
        try await fixture.fake.waitForPendingRequests("script.start")
        await fixture.store.launch(script)
        fixture.fake.resolvePending("script.start", with: ["ok": true])
        await first.value
        #expect(fixture.fake.paramsForMethod("events.subscribe").count == 1)
        #expect(fixture.fake.paramsForMethod("script.start").count == 1)
    }

    @Test func oldRuntimeURLIsIgnoredUntilStartReplyAndFreshStatus() async throws {
        let fixture = WorkspaceScriptFixture()
        await fixture.load([fixture.definition(status: "exited", url: "localhost:3000")])
        let script = try #require(fixture.store.scripts(workspaceId: "workspace").first)
        fixture.fake.responseQueueMap["script.status"] = [fixture.runtime(status: "exited", url: "localhost:3000")]
        fixture.fake.pendingMethods.insert("script.start")
        let launch = Task { await fixture.store.launch(script) }
        try await fixture.fake.waitForPendingRequests("script.start")
        #expect(fixture.store.scripts(workspaceId: "workspace").first?.detectedURL == nil)
        fixture.event(url: "localhost:3000")
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
        fixture.fake.resolvePending("script.start", with: ["ok": true])
        await launch.value
        #expect(fixture.store.scripts(workspaceId: "workspace").first?.detectedURL == nil)
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
        fixture.event(url: "localhost:5000")
        #expect(fixture.store.takeBrowserToOpen(workspaceId: "workspace")?.url == "http://127.0.0.1:5000")
    }

    @Test func runningEventBeforeStartReplyIsRecoveredByStatusRead() async throws {
        let fixture = WorkspaceScriptFixture()
        let script = try await fixture.idleScript()
        fixture.fake.responseQueueMap["script.status"] = [fixture.runtime(status: "idle")]
        fixture.fake.pendingMethods.insert("script.start")
        let launch = Task { await fixture.store.launch(script) }
        try await fixture.fake.waitForPendingRequests("script.start")
        fixture.event(url: "localhost:5000")
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
        fixture.fake.responseMap["script.status"] = fixture.runtime(status: "running", url: "localhost:5000")
        fixture.fake.resolvePending("script.start", with: ["ok": true])
        await launch.value
        #expect(fixture.store.takeBrowserToOpen(workspaceId: "workspace")?.url == "http://127.0.0.1:5000")
    }

    @Test func stoppedEventImmediatelyCancelsEvenWhileStartReplyIsPending() async throws {
        let fixture = WorkspaceScriptFixture()
        let script = try await fixture.idleScript()
        fixture.startReplies(status: "running", url: "localhost:3000")
        fixture.fake.pendingMethods.insert("script.start")
        let launch = Task { await fixture.store.launch(script) }
        try await fixture.fake.waitForPendingRequests("script.start")
        fixture.event(status: "idle")
        #expect(!fixture.store.isLaunching(script))
        #expect(fixture.store.scripts(workspaceId: "workspace").first?.status == "idle")
        fixture.fake.resolvePending("script.start", with: ["ok": true])
        await launch.value
        fixture.event(url: "localhost:3000")
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
    }

    @Test func latestSelectedScriptOwnsPresentationDespiteLateStartFailure() async throws {
        let fixture = WorkspaceScriptFixture()
        await fixture.load([fixture.definition(id: "first"), fixture.definition(id: "second")])
        let scripts = fixture.store.scripts(workspaceId: "workspace")
        fixture.fake.responseQueueMap["script.status"] = [fixture.runtime(status: "idle")]
        fixture.fake.pendingMethods.insert("script.start")
        let first = Task { await fixture.store.launch(scripts[0]) }
        try await fixture.fake.waitForPendingRequests("script.start")
        fixture.fake.responseMap["script.status"] = fixture.runtime(status: "running", url: "localhost:5000")
        await fixture.store.launch(scripts[1])
        fixture.fake.failPending("script.start", with: NSError(domain: "late", code: 1))
        await first.value
        fixture.event(id: "first", url: "localhost:3000")
        #expect(fixture.store.takeBrowserToOpen(workspaceId: "workspace")?.url == "http://127.0.0.1:5000")
        #expect(fixture.store.errorMessage(workspaceId: "workspace") == nil)
    }

    @Test func reselectingAnInflightStartDoesNotSendAnotherStart() async throws {
        let fixture = WorkspaceScriptFixture()
        await fixture.load([fixture.definition(id: "first"), fixture.definition(id: "second")])
        let scripts = fixture.store.scripts(workspaceId: "workspace")
        fixture.fake.responseQueueMap["script.status"] = [fixture.runtime(status: "idle")]
        fixture.fake.pendingMethods.insert("script.start")
        let first = Task { await fixture.store.launch(scripts[0]) }
        try await fixture.fake.waitForPendingRequests("script.start")
        await fixture.store.launch(scripts[1])
        let reselected = Task { await fixture.store.launch(scripts[0]) }
        try await waitUntil("first script selected again") { fixture.store.isLaunching(scripts[0]) }
        fixture.fake.responseMap["script.status"] = fixture.runtime(status: "running", url: "localhost:3000")
        fixture.fake.resolvePending("script.start", with: ["ok": true])
        await first.value
        await reselected.value
        #expect(fixture.fake.paramsForMethod("script.start").count == 1)
        #expect(fixture.store.takeBrowserToOpen(workspaceId: "workspace")?.id == "script:first")
    }

    @Test func newerEventInvalidatesStatusSnapshotBeforeItCanOpenOldURL() async throws {
        let fixture = WorkspaceScriptFixture()
        let script = try await fixture.idleScript()
        fixture.fake.pendingMethods.insert("script.status")
        let launch = Task { await fixture.store.launch(script) }
        try await fixture.fake.waitForPendingRequests("script.status")
        fixture.event(url: "localhost:5000")
        fixture.fake.resolvePending("script.status", with: fixture.runtime(status: "running", url: "localhost:3000"))
        try await fixture.fake.waitForPendingRequests("script.status")
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
        fixture.fake.resolvePending("script.status", with: fixture.runtime(status: "running", url: "localhost:5000"))
        await launch.value
        #expect(fixture.store.takeBrowserToOpen(workspaceId: "workspace")?.url == "http://127.0.0.1:5000")
    }

    @Test func reselectingACommandThatFinishesDuringStartDoesNotRunItTwice() async throws {
        let fixture = WorkspaceScriptFixture()
        await fixture.load([fixture.definition(id: "first"), fixture.definition(id: "second")])
        let scripts = fixture.store.scripts(workspaceId: "workspace")
        fixture.fake.responseQueueMap["script.status"] = [fixture.runtime(status: "idle")]
        fixture.fake.pendingMethods.insert("script.start")
        let first = Task { await fixture.store.launch(scripts[0]) }
        try await fixture.fake.waitForPendingRequests("script.start")
        await fixture.store.launch(scripts[1])
        let reselected = Task { await fixture.store.launch(scripts[0]) }
        try await waitUntil("command selected again") { fixture.store.isLaunching(scripts[0]) }
        fixture.fake.responseMap["script.status"] = fixture.runtime(status: "exited")
        fixture.fake.resolvePending("script.start", with: ["ok": true])
        await first.value
        await reselected.value
        #expect(fixture.fake.paramsForMethod("script.start").count == 1)
        #expect(!fixture.store.isLaunching(scripts[0]))
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
    }

    @Test func runtimeEventInvalidatesAnOlderListWithoutLosingPresentation() async throws {
        let fixture = WorkspaceScriptFixture()
        let script = try await fixture.idleScript()
        fixture.startReplies()
        await fixture.store.launch(script)
        fixture.fake.pendingMethods.insert("script.list")
        let refresh = Task { await fixture.store.refresh(workspaceId: "workspace") }
        try await fixture.fake.waitForPendingRequests("script.list")
        fixture.event(url: "localhost:5000")
        fixture.fake.resolvePending("script.list", with: ["scripts": [fixture.definition(status: "exited", url: "localhost:3000")]])
        try await fixture.fake.waitForPendingRequests("script.list")
        #expect(fixture.store.browserToOpen(workspaceId: "workspace")?.url == "http://127.0.0.1:5000")
        fixture.fake.resolvePending("script.list", with: ["scripts": [fixture.definition(status: "running", url: "localhost:5000")]])
        await refresh.value
        #expect(fixture.store.takeBrowserToOpen(workspaceId: "workspace")?.url == "http://127.0.0.1:5000")
    }

    @Test func deletingScriptClearsPresentationBeforeDefinitionRefreshReturns() async throws {
        let fixture = WorkspaceScriptFixture()
        let script = try await fixture.idleScript()
        fixture.startReplies(status: "running", url: "localhost:3000")
        await fixture.store.launch(script)
        fixture.fake.pendingMethods.insert("script.list")
        let refresh = Task { await fixture.store.refresh(workspaceId: "workspace") }
        try await fixture.fake.waitForPendingRequests("script.list")
        fixture.changed(action: "removed")
        #expect(fixture.store.scripts(workspaceId: "workspace").isEmpty)
        #expect(fixture.store.browserToOpen(workspaceId: "workspace") == nil)
        fixture.fake.resolvePending("script.list", with: ["scripts": [fixture.definition(status: "running", url: "localhost:3000")]])
        try await fixture.fake.waitForPendingRequests("script.list")
        #expect(fixture.store.scripts(workspaceId: "workspace").isEmpty)
        fixture.fake.resolvePending("script.list", with: ["scripts": []])
        await refresh.value
        #expect(fixture.store.scripts(workspaceId: "workspace").isEmpty)
    }

    @Test func reconnectRejectsAnOldDefinitionSnapshot() async throws {
        let fixture = WorkspaceScriptFixture()
        fixture.fake.pendingMethods.insert("script.list")
        let oldRefresh = Task { await fixture.store.refresh(workspaceId: "workspace") }
        try await fixture.fake.waitForPendingRequests("script.list")
        fixture.fake.connectionState = .disconnected
        fixture.fake.resolvePending("script.list", with: ["scripts": [fixture.definition(id: "old")]])
        fixture.fake.pendingMethods.remove("script.list")
        fixture.fake.responseMap["script.list"] = ["scripts": [fixture.definition(id: "new")]]
        fixture.fake.connectionState = .connected
        await oldRefresh.value
        await fixture.store.refresh(workspaceId: "workspace")
        #expect(fixture.store.scripts(workspaceId: "workspace").map(\.id) == ["new"])
    }
}

@MainActor
private final class StartReplyHoldingConnection: FakeConnectionManager {
    let startReplyGate = TestGate()
    private(set) var holdsFirstStartReply = false

    override func request(
        _ method: String,
        params: [String: Any] = [:],
        timeout: TimeInterval = ConnectionManager.defaultRequestTimeout
    ) async throws -> Any {
        let response = try await super.request(method, params: params, timeout: timeout)
        if method == "script.start", !holdsFirstStartReply {
            holdsFirstStartReply = true
            await startReplyGate.wait()
        }
        return response
    }
}
