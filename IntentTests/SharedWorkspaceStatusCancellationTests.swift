import Foundation
@testable import Intent
import Testing

@MainActor
struct SharedWorkspaceStatusCancellationTests {
    private typealias Support = WorkspaceStatusTestSupport

    @Test func cancellationBeforeWaitingDoesNotStartASeedOrPoisonTheNextCaller() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let source = fixture.session.hooksStore
        let owner = source.retain(workspaceId: Support.workspace)
        let cancelled = Task { await source.load(workspaceId: Support.workspace) }
        cancelled.cancel()
        await cancelled.value
        #expect(fixture.connection.traffic().requests.isEmpty)
        await source.load(workspaceId: Support.workspace)
        #expect(fixture.connection.traffic().methodCounts == ["events.subscribe": 1, "hook.list": 1])
        let ids = try Support.acknowledgedIDs(fixture.connection)
        await source.release(workspaceId: Support.workspace, consumer: owner)?.value
        try await Support.waitForCleanup(fixture.connection, events: ids, chats: 0)
    }

    @Test func finalReleaseWakesUncancelledWaitersBeforeEitherRegistrationAck() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let connection = fixture.connection
        connection.pendingMethods = ["events.subscribe"]
        let hooks = fixture.session.hooksStore
        let monitors = fixture.session.prMonitorsStore
        let hookOwner = hooks.retain(workspaceId: Support.workspace)
        let monitorOwner = monitors.retain(workspaceId: Support.workspace)
        var returned = false
        let load = Task {
            async let hookSeed: () = hooks.load(workspaceId: Support.workspace)
            async let monitorSeed: () = monitors.seed(workspaceId: Support.workspace)
            _ = await (hookSeed, monitorSeed)
            returned = true
        }
        defer { load.cancel(); failPending(connection) }
        try await connection.waitForPendingRequests("events.subscribe", count: 2)
        hooks.release(workspaceId: Support.workspace, consumer: hookOwner)
        monitors.release(workspaceId: Support.workspace, consumer: monitorOwner)
        try await waitUntil("final release wakes callers before registration replies") { returned }
        await load.value
        #expect(!load.isCancelled)
        #expect(connection.pendingRequestCount("events.subscribe") == 2)
        connection.resolvePending("events.subscribe", with: ["subscriptionId": "released-1"])
        connection.resolvePending("events.subscribe", with: ["subscriptionId": "released-2"])
        try await Support.waitForCleanup(connection, events: ["released-1", "released-2"], chats: 0)
        #expect(connection.paramsForMethod("hook.list").isEmpty)
        #expect(connection.paramsForMethod("prMonitor.list").isEmpty)
    }

    @Test(arguments: [false, true])
    func cancelledWindowReturnsBeforeSharedAckOrSeedWithoutCancellingOtherWindow(holdSeed: Bool) async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let connection = fixture.connection
        connection.pendingMethods = holdSeed ? ["hook.list", "prMonitor.list"] : ["events.subscribe"]
        let first = fixture.makeViewModel()
        let second = fixture.makeViewModel()
        var firstReturned = false
        var secondReturned = false
        let firstLoad = Task { await first.load(); firstReturned = true }
        let secondLoad = Task { await second.load(); secondReturned = true }
        defer {
            firstLoad.cancel()
            secondLoad.cancel()
            failPending(connection)
        }
        if holdSeed {
            try await connection.waitForPendingRequests("hook.list")
            try await connection.waitForPendingRequests("prMonitor.list")
        } else {
            try await connection.waitForPendingRequests("events.subscribe", count: 2)
        }
        try await waitUntil("both windows retain both shared status caches") {
            fixture.session.hooksStore.buckets[Support.workspace]?.consumers.count == 2
                && fixture.session.prMonitorsStore.cache.buckets[Support.workspace]?.consumers.count == 2
        }
        firstLoad.cancel()
        try await waitUntil("cancelled window returns independently of shared status requests") { firstReturned }
        await firstLoad.value
        #expect(first.activeLiveStoreActivation == nil)
        #expect(second.activeLiveStoreActivation != nil && !secondReturned)
        #expect(connection.traffic().pendingCount == 2)
        #expect(connection.paramsForMethod("events.unsubscribe").isEmpty)
        #expect(fixture.session.hooksStore.buckets[Support.workspace]?.consumers.count == 1)
        #expect(fixture.session.prMonitorsStore.cache.buckets[Support.workspace]?.consumers.count == 1)
        connection.pendingMethods = []
        if holdSeed {
            connection.resolvePending("hook.list", with: ["hooks": []])
            connection.resolvePending("prMonitor.list", with: ["monitors": []])
        } else {
            connection.resolvePending("events.subscribe", with: ["subscriptionId": "shared-1"])
            connection.resolvePending("events.subscribe", with: ["subscriptionId": "shared-2"])
        }
        try await waitUntil("surviving window receives its shared seed") { secondReturned }
        await secondLoad.value
        #expect(connection.paramsForMethod("events.subscribe").count == 2)
        #expect(connection.paramsForMethod("hook.list").count == 1)
        #expect(connection.paramsForMethod("prMonitor.list").count == 1)
        let ids = try Support.acknowledgedIDs(connection)
        second.teardownLiveStores()
        try await Support.waitForCleanup(connection, events: ids, chats: 1)
    }

    @Test func closingWorkspaceReturnsWhileAnotherWorkspaceKeepsTheGlobalMonitorRegistration() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let connection = fixture.connection
        connection.pendingMethods = ["events.subscribe"]
        let model = fixture.makeViewModel()
        var returned = false
        let load = Task { await model.load(); returned = true }
        defer { load.cancel(); failPending(connection) }
        try await connection.waitForPendingRequests("events.subscribe", count: 2)
        let owner = UUID()
        let otherWorkspace = "other-workspace"
        fixture.session.retainWorkspaceStatus(workspaceId: otherWorkspace, consumer: owner)
        try await connection.waitForPendingRequests("events.subscribe", count: 3)
        load.cancel()
        try await waitUntil("closed workspace returns before any status ACK") { returned }
        await load.value
        #expect(connection.pendingRequestCount("events.subscribe") == 3)
        #expect(connection.paramsForMethod("hook.list").isEmpty)
        #expect(connection.paramsForMethod("prMonitor.list").isEmpty)
        let registrations = connection.paramsForMethod("events.subscribe")
        let ids = Set(registrations.indices.map { "workspace-feed-\($0)" })
        let orphanIndex = try #require(registrations.firstIndex { $0["workspaceId"] as? String == Support.workspace })
        connection.pendingMethods = []
        for index in registrations.indices {
            connection.resolvePending("events.subscribe", with: ["subscriptionId": "workspace-feed-\(index)"])
        }
        try await waitUntil("other workspace seeds and the orphan hook ACK is released") {
            connection.paramsForMethod("hook.list").count == 1 && connection.paramsForMethod("prMonitor.list").count == 1
                && connection.paramsForMethod("events.unsubscribe").count == 1 && connection.traffic().pendingCount == 0
        }
        for method in ["hook.list", "prMonitor.list"] {
            #expect(connection.paramsForMethod(method).first?["workspaceId"] as? String == otherWorkspace)
        }
        #expect(connection.paramsForMethod("events.unsubscribe").first?["subscriptionId"] as? String == "workspace-feed-\(orphanIndex)")
        #expect(fixture.session.prMonitorsStore.cache.feeds[""]?.id != nil)
        fixture.session.releaseWorkspaceStatus(workspaceId: otherWorkspace, consumer: owner)
        try await Support.waitForCleanup(connection, events: ids, chats: 1)
    }

    @Test(arguments: [false, true])
    func cancelledFinalLoadReleasesStoresBeforeAckAndKeepsOnlyConnectionBoundCleanup(reconnect: Bool) async throws {
        var fixture: ConversationStartupFixture? = ConversationStartupFixture()
        let connection = try #require(fixture?.connection)
        connection.releaseConnectionStateDelivery()
        connection.pendingMethods = ["events.subscribe"]
        var model = fixture?.makeViewModel()
        weak var hooks = fixture?.session.hooksStore
        weak var monitors = fixture?.session.prMonitorsStore.cache
        weak var hookLifetime = hooks?.connectionLifetime
        weak var monitorLifetime = monitors?.connectionLifetime
        var returned = false
        let load = Task { await model?.load(); returned = true }
        defer { load.cancel(); fixture?.stop(); failPending(connection) }
        try await connection.waitForPendingRequests("events.subscribe", count: 2)
        load.cancel()
        model?.conversationDisappeared()
        try await waitUntil("final cancelled load returns without either status ACK") { returned }
        await load.value
        #expect(connection.pendingRequestCount("events.subscribe") == 2)
        #expect(connection.paramsForMethod("hook.list").isEmpty)
        #expect(connection.paramsForMethod("prMonitor.list").isEmpty)
        model = nil
        fixture?.stop()
        fixture = nil
        try await waitUntil("closed status stores released while orphan ACKs are still held") { hooks == nil && monitors == nil }
        #expect(hookLifetime != nil && monitorLifetime != nil, "orphan registrations still need connection provenance")
        if reconnect {
            connection.simulateDisconnect()
            connection.simulateConnect()
        }
        connection.resolvePending("events.subscribe", with: ["subscriptionId": "closed-hook"])
        connection.resolvePending("events.subscribe", with: ["subscriptionId": "closed-monitor"])
        if reconnect {
            try await waitUntil("old socket ACK tasks finish") { connection.traffic().pendingCount == 0 }
            #expect(connection.paramsForMethod("events.unsubscribe").isEmpty)
        } else {
            try await Support.waitForCleanup(connection, events: ["closed-hook", "closed-monitor"], chats: 1)
        }
        try await waitUntil("orphan cleanup releases both connection observers") { hookLifetime == nil && monitorLifetime == nil }
        #expect(connection.paramsForMethod("hook.list").isEmpty)
        #expect(connection.paramsForMethod("prMonitor.list").isEmpty)
    }

    private func failPending(_ connection: RPCRecordingConnection) {
        for method in ["events.subscribe", "hook.list", "prMonitor.list"] {
            while connection.pendingRequestCount(method) > 0 {
                connection.failPending(method, with: CancellationError())
            }
        }
    }
}
