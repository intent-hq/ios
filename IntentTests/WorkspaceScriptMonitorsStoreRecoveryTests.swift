import Foundation
@testable import Intent
import Testing

extension WorkspaceScriptMonitorsStoreTests {
    @Test func overflowInvalidatesSeedAndRecoveryIsBounded() async throws {
        let fake = fake()
        fake.pendingMethods = ["scriptMonitor.list"]
        let store = WorkspaceScriptMonitorsStore(connection: fake) { true }
        store.retain(workspaceId: "ws-1")
        let load = Task { await store.load(workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("scriptMonitor.list")
        let limit = WorkspaceStatusStore<ScriptMonitorSummary>.journalLimit
        for index in 0...limit { event(store, "expired", monitor("removed-\(index)")) }
        #expect(store.cache.buckets["ws-1"]?.events.count ?? 0 <= limit)
        #expect(store.cache.buckets["ws-1"]?.tombstones.count ?? 0 <= limit)
        fake.resolvePending("scriptMonitor.list", with: page([monitor("removed-0")]))
        try await fake.waitForRequests("scriptMonitor.list", count: 2)
        try await fake.waitForPendingRequests("scriptMonitor.list")
        for index in 0...limit { event(store, "expired", monitor("removed-again-\(index)")) }
        fake.resolvePending("scriptMonitor.list", with: page([monitor("removed-again-0")]))
        await load.value
        #expect(store.rows(for: "ws-1").isEmpty)
        #expect(store.isStale(for: "ws-1"))
        #expect(store.error(for: "ws-1") != nil)
        event(store, "registered", ["workspaceId": "ws-1"])
        try await expectNever("unbounded automatic recovery") {
            fake.paramsForMethod("scriptMonitor.list").count > 2
        }
    }

    @Test func accessLossClearsRowsAndSelectedDetailsUntilExplicitRetry() async {
        let fake = fake()
        fake.responseMap["scriptMonitor.get"] = monitor()
        let store = WorkspaceScriptMonitorsStore(connection: fake) { true }
        store.retain(workspaceId: "ws-1")
        await store.load(workspaceId: "ws-1")
        let selected = store.select(workspaceId: "ws-1", monitorId: "monitor-1")
        await store.loadDetail(selection: selected)
        fake.errorMap["scriptMonitor.list"] = NSError(domain: "WebSocket", code: WorkspaceScriptMonitorsStore.forbidden)
        await store.refresh(workspaceId: "ws-1")
        #expect(store.rows(for: "ws-1").isEmpty)
        #expect(store.detailSummary(selection: selected) == nil)
        #expect(store.error(for: "ws-1") != nil)
        event(store, "registered", monitor())
        #expect(store.rows(for: "ws-1").isEmpty)
        fake.errorMap = [:]
        await store.retry(workspaceId: "ws-1")
        #expect(store.rows(for: "ws-1").count == 1)
    }

    @Test func finalLeaseDiscardsLateAckWithoutReadingOrLeakingSuccessorFeed() async throws {
        let fake = fake()
        fake.pendingMethods = ["events.subscribe"]
        let store = WorkspaceScriptMonitorsStore(connection: fake) { true }
        let first = store.retain(workspaceId: "ws-1")
        let oldLoad = Task { await store.load(workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("events.subscribe")
        store.release(workspaceId: "ws-1", consumer: first)
        store.retain(workspaceId: "ws-1")
        let newLoad = Task { await store.load(workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("events.subscribe", count: 2)
        fake.resolvePending("events.subscribe", with: ["subscriptionId": "old-feed"])
        fake.resolvePending("events.subscribe", with: ["subscriptionId": "new-feed"])
        await oldLoad.value
        await newLoad.value
        try await fake.waitForRequests("events.unsubscribe")
        #expect(fake.paramsForMethod("scriptMonitor.list").count == 1)
        #expect(fake.paramsForMethod("events.unsubscribe").first?["subscriptionId"] as? String == "old-feed")
        #expect(store.cache.feeds["ws-1"]?.id == "new-feed")
    }

    @Test func malformedPageIsAnErrorAndDoesNotPublishPartialRows() async {
        let fake = fake()
        fake.responseMap["scriptMonitor.list"] = page([monitor(), ["monitorId": "broken"]])
        let store = WorkspaceScriptMonitorsStore(connection: fake) { true }
        store.retain(workspaceId: "ws-1")
        await store.load(workspaceId: "ws-1")
        #expect(store.rows(for: "ws-1").isEmpty)
        #expect(store.error(for: "ws-1") != nil)
        #expect(store.isSupported)
        #expect(store.isStale(for: "ws-1"))
    }

    @Test func missingDetailDoesNotInferOutcomeAndCoalescesFirstPageRefresh() async throws {
        let fake = fake()
        let store = WorkspaceScriptMonitorsStore(connection: fake) { true }
        store.retain(workspaceId: "ws-1")
        await store.load(workspaceId: "ws-1")
        let selected = store.select(workspaceId: "ws-1", monitorId: "monitor-1")
        fake.errorMap["scriptMonitor.get"] = NSError(domain: "WebSocket", code: WorkspaceScriptMonitorsStore.invalidParameters)
        await store.loadDetail(selection: selected)
        #expect(store.detailState(selection: selected) == .unavailable)
        #expect(store.detailSummary(selection: selected) == nil)
        try await fake.waitForRequests("scriptMonitor.list", count: 2)
        await store.loadDetail(selection: selected, retry: true)
        #expect(fake.paramsForMethod("scriptMonitor.get").count == 1)
    }
}

extension WorkspaceScriptMonitorsStoreTests {
    @Test func detailAccessLossInvalidatesConcurrentPageReply() async throws {
        let fake = fake()
        fake.responseMap["scriptMonitor.list"] = page([monitor()], cursor: "next")
        let store = WorkspaceScriptMonitorsStore(connection: fake) { true }
        store.retain(workspaceId: "ws-1")
        await store.load(workspaceId: "ws-1")
        let selected = store.select(workspaceId: "ws-1", monitorId: "monitor-1")
        fake.pendingMethods = ["scriptMonitor.get", "scriptMonitor.list"]
        let details = Task { await store.loadDetail(selection: selected) }
        try await fake.waitForPendingRequests("scriptMonitor.get")
        let next = Task { await store.loadMore(workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("scriptMonitor.list")
        fake.failPending("scriptMonitor.get", with: NSError(domain: "WebSocket", code: WorkspaceScriptMonitorsStore.forbidden))
        await details.value
        fake.resolvePending("scriptMonitor.list", with: page([monitor("late-private-row")]))
        await next.value
        #expect(store.rows(for: "ws-1").isEmpty)
        #expect(store.detailSummary(selection: selected) == nil)
        #expect(store.error(for: "ws-1") != nil)
    }

    @Test func retryDetailTransportFailureDoesNotRestartSummaryPaging() async {
        let fake = fake()
        fake.responseMap["scriptMonitor.list"] = page([monitor()], cursor: "next")
        fake.errorMap["scriptMonitor.get"] = URLError(.timedOut)
        let store = WorkspaceScriptMonitorsStore(connection: fake) { true }
        store.retain(workspaceId: "ws-1")
        await store.load(workspaceId: "ws-1")
        let selected = store.select(workspaceId: "ws-1", monitorId: "monitor-1")
        await store.loadDetail(selection: selected)
        #expect(store.detailSummary(selection: selected)?.scriptName == "Build")
        fake.errorMap = [:]
        fake.responseMap["scriptMonitor.get"] = monitor()
        await store.loadDetail(selection: selected, retry: true)
        #expect(fake.paramsForMethod("scriptMonitor.get").count == 2)
        #expect(fake.paramsForMethod("scriptMonitor.list").count == 1)
        #expect(store.nextCursor(for: "ws-1") == "next")
    }
}

extension WorkspaceScriptMonitorsStoreTests {
    @Test func completeEventsOutsideReadsNeverTriggerRecoveryForCapacity() async throws {
        let fake = fake()
        let store = WorkspaceScriptMonitorsStore(connection: fake) { true }
        store.retain(workspaceId: "ws-1")
        await store.load(workspaceId: "ws-1")
        let limit = WorkspaceStatusStore<ScriptMonitorSummary>.journalLimit
        for index in 0...limit { event(store, "completed", monitor("completed-\(index)")) }
        try await expectNever("a read for complete idle events") {
            fake.paramsForMethod("scriptMonitor.list").count > 1
        }
        #expect(store.cache.buckets["ws-1"]?.tombstones.count ?? 0 <= limit)
    }
}

extension WorkspaceScriptMonitorsStoreTests {
    @Test func failedRecoveryWaitsForExplicitRetry() async throws {
        let fake = fake()
        fake.responseMap["scriptMonitor.list"] = page([monitor()], cursor: "next")
        let store = WorkspaceScriptMonitorsStore(connection: fake) { true }
        store.retain(workspaceId: "ws-1")
        await store.load(workspaceId: "ws-1")
        fake.errorMap["scriptMonitor.list"] = URLError(.timedOut)
        event(store, "registered", ["workspaceId": "ws-1"])
        try await waitUntil("failed recovery") {
            fake.paramsForMethod("scriptMonitor.list").count == 2 && !store.isLoading(for: "ws-1")
        }
        for _ in 0..<3 { event(store, "registered", ["workspaceId": "ws-1"]) }
        try await expectNever("automatic retry after recovery failure") {
            fake.paramsForMethod("scriptMonitor.list").count > 2
        }
        #expect(store.rows(for: "ws-1").count == 1)
        #expect(store.nextCursor(for: "ws-1") == "next")
        #expect(store.error(for: "ws-1") != nil)
        fake.errorMap = [:]
        await store.retry(workspaceId: "ws-1")
        #expect(fake.paramsForMethod("scriptMonitor.list").count == 3)
        #expect(store.error(for: "ws-1") == nil)
        event(store, "registered", ["workspaceId": "ws-1"])
        try await fake.waitForRequests("scriptMonitor.list", count: 4)
    }

    @Test func recoveryRevalidatesSelectedWatchAfterLostTerminalEvent() async throws {
        let fake = fake()
        fake.responseMap["scriptMonitor.get"] = monitor()
        let store = WorkspaceScriptMonitorsStore(connection: fake) { true }
        store.retain(workspaceId: "ws-1")
        await store.load(workspaceId: "ws-1")
        let selected = store.select(workspaceId: "ws-1", monitorId: "monitor-1")
        await store.loadDetail(selection: selected)
        fake.responseMap["scriptMonitor.list"] = page([])
        fake.errorMap["scriptMonitor.get"] = NSError(domain: "WebSocket", code: WorkspaceScriptMonitorsStore.invalidParameters)
        event(store, "completed", ["workspaceId": "ws-1"])
        try await waitUntil("revalidated missing watch") { store.detailState(selection: selected) == .unavailable }
        #expect(store.rows(for: "ws-1").isEmpty)
        #expect(store.detailSummary(selection: selected) == nil)
        #expect(fake.paramsForMethod("scriptMonitor.get").count == 2)
    }

    @Test func explicitRefreshRevalidatesActiveOffPageSelection() async throws {
        let fake = fake()
        fake.responseMap["scriptMonitor.get"] = monitor()
        let store = WorkspaceScriptMonitorsStore(connection: fake) { true }
        store.retain(workspaceId: "ws-1")
        await store.load(workspaceId: "ws-1")
        let selected = store.select(workspaceId: "ws-1", monitorId: "monitor-1")
        await store.loadDetail(selection: selected)
        fake.responseMap["scriptMonitor.list"] = page([monitor("another-watch")], cursor: "next")
        var updated = monitor()
        updated["scriptName"] = "Updated off-page script"
        fake.responseMap["scriptMonitor.get"] = updated
        await store.refresh(workspaceId: "ws-1")
        try await waitUntil("updated selected detail") {
            store.detailSummary(selection: selected)?.scriptName == "Updated off-page script"
        }
        if case .loaded = store.detailState(selection: selected) {} else { Issue.record("Off-page watch must stay available") }
        #expect(store.rows(for: "ws-1").map(\.monitorId) == ["another-watch"])
        #expect(store.nextCursor(for: "ws-1") == "next")
        #expect(fake.paramsForMethod("scriptMonitor.list").count == 2)
        #expect(fake.paramsForMethod("scriptMonitor.get").count == 2)
        await store.loadMore(workspaceId: "ws-1")
        #expect(fake.paramsForMethod("scriptMonitor.get").count == 2, "Appending a page must not refresh open details")
    }
}
