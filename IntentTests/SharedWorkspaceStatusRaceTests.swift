import Foundation
@testable import Intent
import Testing

@MainActor
struct SharedWorkspaceStatusRaceTests {
    private typealias Support = WorkspaceStatusTestSupport

    @Test func completedRemovalCancelsAQueuedRecoveryBeforeItStarts() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        await fixture.makeViewModel().load()
        let checkpoint = fixture.connection.checkpoint
        for (prefix, sourceIsHook) in [("hook", true), ("prMonitor", false)] {
            let key = sourceIsHook ? "hookId" : "monitorId"
            for suffix in [sourceIsHook ? "scheduled" : "registered", "cancelled"] {
                let params: [String: Any] = [
                    "type": "\(prefix):\(suffix)", "workspaceId": Support.workspace,
                    "data": [key: "removed-before-read", "workspaceId": Support.workspace]
                ]
                if sourceIsHook {
                    fixture.session.hooksStore.handleEvent(params)
                } else {
                    fixture.session.prMonitorsStore.handleEvent("events.event", params: params)
                }
            }
        }
        try await expectNever("recovery after a complete removal") {
            !fixture.connection.traffic(since: checkpoint).requests.isEmpty
        }
    }

    @Test func cancellationResolvesAnIncompleteEarlierEventWithoutRecovery() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let model = fixture.makeViewModel()
        let connection = fixture.connection
        connection.pendingMethods = ["hook.list", "prMonitor.list"]
        let load = Task { await model.load() }
        defer { load.cancel() }
        try await connection.waitForPendingRequests("hook.list")
        try await connection.waitForPendingRequests("prMonitor.list")
        Support.event(fixture, type: "hook:scheduled", id: "never-listed")
        Support.event(fixture, type: "hook:cancelled", id: "never-listed")
        Support.event(fixture, type: "prMonitor:registered", id: "never-listed")
        Support.event(fixture, type: "prMonitor:cancelled", id: "never-listed")
        try await waitUntil("terminal events buffered") {
            fixture.session.hooksStore.buckets[Support.workspace]?.events.last?.0 == "hook:cancelled"
                && fixture.session.prMonitorsStore.cache.buckets[Support.workspace]?.events.last?.0 == "prMonitor:cancelled"
        }
        connection.pendingMethods = []
        connection.resolvePending("hook.list", with: ["hooks": []])
        connection.resolvePending("prMonitor.list", with: ["monitors": []])
        await load.value
        #expect(connection.paramsForMethod("hook.list").count == 1)
        #expect(connection.paramsForMethod("prMonitor.list").count == 1)
        #expect(!model.hookStore.isStale && !model.monitoredPrStore.isStale)
    }

    @Test func coldSeedReplaysDuringReadEventsWithoutAnotherList() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let model = fixture.makeViewModel()
        let connection = fixture.connection
        connection.pendingMethods = ["hook.list", "prMonitor.list"]
        let load = Task { await model.load() }
        defer { load.cancel() }
        try await connection.waitForPendingRequests("hook.list")
        try await connection.waitForPendingRequests("prMonitor.list")
        #expect(!model.isLoading && !model.messages.isEmpty, "transcript is independent of status seeds")
        Support.event(fixture, type: "hook:cancelled", id: "hook-1")
        Support.event(fixture, type: "hook:run-started", id: "hook-2")
        Support.event(fixture, type: "prMonitor:cancelled", id: "monitor-1")
        Support.event(fixture, type: "prMonitor:completed", id: "monitor-2", extra: ["state": "completed"])
        try await waitUntil("seed events buffered") {
            fixture.session.hooksStore.buckets[Support.workspace]?.events.count == 2
                && fixture.session.prMonitorsStore.cache.buckets[Support.workspace]?.events.count == 2
        }
        connection.resolvePending("hook.list", with: ["hooks": [Support.hook(), Support.hook("hook-2")]])
        connection.resolvePending("prMonitor.list", with: ["monitors": [Support.monitor(), Support.monitor("monitor-2")]])
        await load.value
        #expect(model.hookStore.hooks.map(\.hookId) == ["hook-2"])
        #expect(model.hookStore.hooks.first?.state == .running)
        #expect(model.monitoredPrStore.monitors.map(\.monitorId) == ["monitor-2"])
        #expect(model.monitoredPrStore.monitors.first?.state == .completed)
        #expect(model.monitoredPrStore.monitors.first?.hasPendingChanges == false)
        #expect(connection.paramsForMethod("hook.list").count == 1)
        #expect(connection.paramsForMethod("prMonitor.list").count == 1)
        #expect(!model.hookStore.isStale && !model.monitoredPrStore.isStale)
    }

    @Test func successfulReadSupersedesEventsBeforeItsStart() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        Support.seedRows(fixture)
        let model = fixture.makeViewModel()
        let connection = fixture.connection
        connection.pendingMethods = ["events.subscribe"]
        let load = Task { await model.load() }
        defer { load.cancel() }
        try await connection.waitForPendingRequests("events.subscribe", count: 2)
        Support.event(fixture, type: "hook:cancelled", id: "hook-1")
        Support.event(fixture, type: "prMonitor:cancelled", id: "monitor-1")
        try await waitUntil("pre-read events delivered") {
            fixture.session.hooksStore.buckets[Support.workspace]?.events.count == 1
                && fixture.session.prMonitorsStore.cache.buckets[Support.workspace]?.events.count == 1
        }
        #expect(!connection.didCallMethod("hook.list") && !connection.didCallMethod("prMonitor.list"))
        connection.resolvePending("events.subscribe", with: ["subscriptionId": "pre-read-feed-1"])
        connection.resolvePending("events.subscribe", with: ["subscriptionId": "pre-read-feed-2"])
        await load.value
        #expect(model.hookStore.hooks.map(\.hookId) == ["hook-1"])
        #expect(model.monitoredPrStore.monitors.map(\.monitorId) == ["monitor-1"])
        #expect(connection.paramsForMethod("hook.list").count == 1)
        #expect(connection.paramsForMethod("prMonitor.list").count == 1)
    }

    @Test func incompleteEventsCoalesceAndRecoveryStopsAfterOneFollowUp() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let model = fixture.makeViewModel()
        let connection = fixture.connection
        connection.pendingMethods = ["hook.list", "prMonitor.list"]
        let load = Task { await model.load() }
        defer { load.cancel() }
        for attempt in 1...2 {
            try await connection.waitForRequests("hook.list", count: attempt)
            try await connection.waitForRequests("prMonitor.list", count: attempt)
            for index in 0..<10 {
                Support.event(fixture, type: "hook:scheduled", id: "missing-hook-\(index)")
                Support.event(fixture, type: "prMonitor:registered", id: "missing-monitor-\(index)")
            }
            try await waitUntil("incomplete event burst buffered") {
                fixture.session.hooksStore.buckets[Support.workspace]?.events.count == 10
                    && fixture.session.prMonitorsStore.cache.buckets[Support.workspace]?.events.count == 10
            }
            connection.resolvePending("hook.list", with: ["hooks": []])
            connection.resolvePending("prMonitor.list", with: ["monitors": []])
        }
        await load.value
        try await expectNever("unbounded incomplete-event recovery") {
            connection.paramsForMethod("hook.list").count > 2 || connection.paramsForMethod("prMonitor.list").count > 2
        }
        #expect(model.hookStore.isStale && model.monitoredPrStore.isStale)
        #expect(model.hookStore.error != nil && model.monitoredPrStore.error != nil)
        #expect(connection.traffic().pendingCount == 0)
    }

    @Test func disconnectDuringSeedRejectsOldRepliesAndReseedsEachActiveWorkspaceOnce() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        fixture.connection.releaseConnectionStateDelivery()
        let firstOwner = UUID()
        let secondOwner = UUID()
        fixture.connection.pendingMethods = ["hook.list", "prMonitor.list"]
        fixture.session.retainWorkspaceStatus(workspaceId: Support.workspace, consumer: firstOwner)
        fixture.session.retainWorkspaceStatus(workspaceId: "second-workspace", consumer: secondOwner)
        try await fixture.connection.waitForPendingRequests("hook.list", count: 2)
        try await fixture.connection.waitForPendingRequests("prMonitor.list", count: 2)
        fixture.connection.simulateDisconnect()
        fixture.connection.pendingMethods = []
        fixture.connection.simulateConnect()
        fixture.connection.simulateConnect()
        try await fixture.connection.waitForRequests("hook.list", count: 4)
        try await fixture.connection.waitForRequests("prMonitor.list", count: 4)
        for _ in 0..<2 {
            fixture.connection.resolvePending("hook.list", with: ["hooks": [Support.hook()]])
            fixture.connection.resolvePending("prMonitor.list", with: ["monitors": [Support.monitor()]])
        }
        try await waitUntil("obsolete reads completed") { fixture.connection.traffic().pendingCount == 0 }
        #expect(fixture.session.hooksStore.buckets.values.allSatisfy { $0.rows.isEmpty && !$0.isStale })
        #expect(fixture.session.prMonitorsStore.cache.buckets.values.allSatisfy { $0.rows.isEmpty && !$0.isStale })
        #expect(fixture.connection.paramsForMethod("events.subscribe").count == 6, "two scoped hooks and one global PR feed per epoch")
        #expect(fixture.connection.paramsForMethod("events.unsubscribe").isEmpty, "dead socket IDs are not sent to the new socket")
    }
}
