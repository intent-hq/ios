import Foundation
@testable import Intent
import Testing

@MainActor
struct SharedWorkspaceStatusLifetimeTests {
    private typealias Support = WorkspaceStatusTestSupport

    @Test func queuedCleanupMustNotSendOldFeedIDsOnNewSocket() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let connection = fixture.connection
        connection.releaseConnectionStateDelivery()
        let model = fixture.makeViewModel()
        await model.load()
        let oldIDs = try Support.acknowledgedIDs(connection)
        #expect(oldIDs.count == 2)
        let checkpoint = connection.checkpoint
        // No suspension: cleanup cannot start until the socket has changed.
        model.hookStore.deactivate()
        model.monitoredPrStore.deactivate()
        connection.simulateDisconnect()
        connection.simulateConnect()
        await model.hookStore.subscribe(workspaceId: Support.workspace, agentId: ConversationStartupFixture.parentId)
        await model.monitoredPrStore.subscribe(workspaceId: Support.workspace, agentId: ConversationStartupFixture.parentId)
        #expect(connection.traffic(since: checkpoint).calls("events.unsubscribe").isEmpty)
        let currentIDs = try Support.acknowledgedIDs(connection).subtracting(oldIDs)
        #expect(currentIDs.count == 2)
        model.teardownLiveStores()
        try await Support.waitForCleanup(connection, events: currentIDs, chats: 1)
    }

    @Test func reconnectDuringFeedRegistrationNeverUnsubscribesOldSocketIDsOnTheNewSocket() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let connection = fixture.connection
        connection.releaseConnectionStateDelivery()
        connection.pendingMethods = ["events.subscribe"]
        let model = fixture.makeViewModel()
        let load = Task { await model.load() }
        defer { load.cancel() }
        try await connection.waitForPendingRequests("events.subscribe", count: 2)
        connection.simulateDisconnect()
        connection.pendingMethods = []
        connection.simulateConnect()
        connection.simulateConnect()
        try await waitUntil("new socket feeds acknowledged and seeded") {
            connection.traffic().calls("hook.list").first?.completed != nil
                && connection.traffic().calls("prMonitor.list").first?.completed != nil
        }
        let current = try Support.acknowledgedIDs(connection)
        #expect(current.count == 2)
        connection.resolvePending("events.subscribe", with: ["subscriptionId": "dead-socket-1"])
        connection.resolvePending("events.subscribe", with: ["subscriptionId": "dead-socket-2"])
        await load.value
        #expect(connection.paramsForMethod("events.unsubscribe").isEmpty)
        #expect(connection.paramsForMethod("events.subscribe").count == 4)
        #expect(connection.paramsForMethod("hook.list").count == 1)
        #expect(connection.paramsForMethod("prMonitor.list").count == 1)
        #expect(!model.hookStore.isStale && !model.monitoredPrStore.isStale)
        model.teardownLiveStores()
        try await Support.waitForCleanup(connection, events: current, chats: 1)
    }

    @Test func lastConsumerCancelsSeedReadsWhileKeepingLateAckCleanupIndependent() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let connection = fixture.connection
        connection.pendingMethods = ["hook.list", "prMonitor.list"]
        let model = fixture.makeViewModel()
        let load = Task { await model.load() }
        defer {
            connection.resolvePending("hook.list", with: ["hooks": []])
            connection.resolvePending("prMonitor.list", with: ["monitors": []])
            load.cancel()
        }
        try await connection.waitForPendingRequests("hook.list")
        try await connection.waitForPendingRequests("prMonitor.list")
        model.teardownLiveStores()
        try await waitUntil("unused reads cancelled and acknowledged feeds released") {
            connection.traffic().pendingCount == 0 && connection.paramsForMethod("events.unsubscribe").count == 2
        }
        await load.value
        #expect(model.hookStore.hooks.isEmpty && model.monitoredPrStore.monitors.isEmpty)
    }

    @Test func windowLeaseKeepsSequentialAToBToAWarmAndFinalReleaseCleansUp() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let connection = fixture.connection
        let owner = UUID()
        fixture.session.retainWorkspaceStatus(workspaceId: Support.workspace, consumer: owner)
        let first = fixture.makeViewModel()
        await first.load()
        let cold = connection.traffic()
        #expect(cold.requests.count == 8 && cold.pendingCount == 0)
        print("Cold window plus first conversation: \(cold.summary)")
        let ids = try Support.acknowledgedIDs(connection)
        for model in [fixture.makeViewModel(agentId: "startup-second"), first] {
            let previous = fixture.viewModels.first { $0.activeLiveStoreActivation != nil }
            let previousReleases = connection.paramsForMethod("chat.unsubscribe").count
            previous?.teardownLiveStores()
            try await waitUntil("previous chat release") {
                connection.traffic().pendingCount == 0 && connection.paramsForMethod("chat.unsubscribe").count == previousReleases + 1
            }
            let checkpoint = connection.checkpoint
            await model.load()
            let warm = connection.traffic(since: checkpoint)
            #expect(warm.methodCounts == ["agent.get": 1, "chat.subscribe": 1, "agent.getQueue": 1, "agent.getSubscriptions": 1])
            #expect(warm.pendingCount == 0)
            print("Warm switch: \(warm.summary)")
        }
        let checkpoint = connection.checkpoint
        first.teardownLiveStores()
        #expect(connection.paramsForMethod("events.unsubscribe").isEmpty)
        fixture.session.releaseWorkspaceStatus(workspaceId: Support.workspace, consumer: owner)
        try await Support.waitForCleanup(connection, events: ids, chats: 3)
        #expect(fixture.session.hooksStore.eventHandlerId == nil)
        #expect(fixture.session.prMonitorsStore.cache.eventHandlerId == nil)
        let cleanup = connection.traffic(since: checkpoint)
        #expect(cleanup.methodCounts == ["events.unsubscribe": 2, "chat.unsubscribe": 1])
        print("Final window cleanup: \(cleanup.summary)")
        print("Complete A-B-A including earlier chat releases: \(connection.traffic().summary)")
    }

    @Test func duplicateWindowAndRowLeasesShareReconnectAndReleaseOnlyTheFinalOwner() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let connection = fixture.connection
        let owners = [UUID(), UUID()]
        for owner in owners { fixture.session.retainWorkspaceStatus(workspaceId: Support.workspace, consumer: owner) }
        let row = fixture.session.prMonitorsStore.retain(workspaceId: Support.workspace)
        let first = fixture.makeViewModel()
        await first.load()
        let checkpoint = connection.checkpoint
        let second = fixture.makeViewModel()
        await second.load()
        await fixture.session.prMonitorsStore.seed(workspaceId: Support.workspace)
        #expect(connection.traffic(since: checkpoint).requests.isEmpty)
        print("Retained duplicate: \(connection.traffic(since: checkpoint).summary)")
        connection.releaseConnectionStateDelivery()
        connection.simulateConnect()
        try await expectNever("same-generation status replay") { !connection.traffic(since: checkpoint).requests.isEmpty }
        connection.simulateDisconnect()
        connection.simulateConnect()
        connection.simulateConnect()
        try await waitUntil("one full reconnect") {
            let traffic = connection.traffic(since: checkpoint)
            return traffic.calls("prMonitor.list").count == 1 && traffic.calls("hook.list").count == 1
                && traffic.calls("agent.getQueue").count == 1 && traffic.pendingCount == 0
        }
        let reconnect = connection.traffic(since: checkpoint)
        #expect(reconnect.methodCounts == [
            "events.subscribe": 2, "hook.list": 1, "prMonitor.list": 1, "browser.syncTabs": 1,
            "chat.subscribe": 1, "agent.get": 1, "agent.getQueue": 1, "agent.getSubscriptions": 1
        ])
        print("Shared reconnect: \(reconnect.summary)")
        first.teardownLiveStores()
        second.teardownLiveStores()
        for owner in owners { fixture.session.releaseWorkspaceStatus(workspaceId: Support.workspace, consumer: owner) }
        #expect(fixture.session.prMonitorsStore.cache.eventHandlerId != nil, "row still owns the global monitor feed")
        await fixture.session.prMonitorsStore.release(workspaceId: Support.workspace, consumer: row)?.value
        try await waitUntil("two live-epoch status releases completed") {
            connection.traffic().calls("events.unsubscribe").count == 2 && connection.traffic().pendingCount == 0
        }
        #expect(fixture.session.prMonitorsStore.cache.eventHandlerId == nil)
    }

    @Test(arguments: [false, true])
    func lateAcksAfterLastConsumerReleaseOnlyTheirOwnIDs(reopen: Bool) async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let connection = fixture.connection
        connection.pendingMethods = ["events.subscribe"]
        let model = fixture.makeViewModel()
        let oldLoad = Task { await model.load() }
        defer { oldLoad.cancel() }
        try await connection.waitForPendingRequests("events.subscribe", count: 2)
        model.teardownLiveStores()
        connection.pendingMethods = []
        if reopen { await model.load() }
        let current = try Support.acknowledgedIDs(connection)
        #expect(current.count == (reopen ? 2 : 0))
        connection.resolvePending("events.subscribe", with: ["subscriptionId": "orphan-hook"])
        connection.resolvePending("events.subscribe", with: ["subscriptionId": "orphan-monitor"])
        await oldLoad.value
        try await waitUntil("orphan release completed") {
            connection.traffic().calls("events.unsubscribe").count == 2 && connection.traffic().pendingCount == 0
        }
        #expect(Set(connection.paramsForMethod("events.unsubscribe").compactMap { $0["subscriptionId"] as? String })
            == ["orphan-hook", "orphan-monitor"])
        #expect(connection.paramsForMethod("hook.list").count == (reopen ? 1 : 0))
        #expect(connection.paramsForMethod("prMonitor.list").count == (reopen ? 1 : 0))
        #expect((model.activeLiveStoreActivation != nil) == reopen)
        model.teardownLiveStores()
        try await Support.waitForCleanup(connection, events: current.union(["orphan-hook", "orphan-monitor"]), chats: reopen ? 2 : 1)
    }

    @Test func backendTeardownClearsOnlyItsCachesAndCannotReseedFromOldReplies() async throws {
        let first = ConversationStartupFixture()
        let second = ConversationStartupFixture()
        defer { first.stop(); second.stop() }
        Support.seedRows(first)
        Support.seedRows(second)
        let modelA = first.makeViewModel()
        let modelB = second.makeViewModel()
        await modelA.load()
        await modelB.load()
        Support.event(first, type: "hook:cancelled", id: "hook-1")
        Support.event(first, type: "prMonitor:cancelled", id: "monitor-1")
        try await waitUntil("first backend event folds") { modelA.hookStore.hooks.isEmpty && modelA.monitoredPrStore.monitors.isEmpty }
        #expect(modelB.hookStore.hooks.count == 1 && modelB.monitoredPrStore.monitors.count == 1)
        first.connection.pendingMethods = ["hook.list", "prMonitor.list"]
        let hookRead = Task { await modelA.hookStore.refetch() }
        let monitorRead = Task { await modelA.monitoredPrStore.refetch() }
        try await first.connection.waitForPendingRequests("hook.list")
        try await first.connection.waitForPendingRequests("prMonitor.list")
        first.session.teardown()
        first.connection.resolvePending("hook.list", with: ["hooks": [Support.hook()]])
        first.connection.resolvePending("prMonitor.list", with: ["monitors": [Support.monitor()]])
        await hookRead.value
        await monitorRead.value
        #expect(first.session.hooksStore.buckets.isEmpty && first.session.prMonitorsStore.cache.buckets.isEmpty)
        #expect(second.connection.paramsForMethod("events.subscribe").count == 2)
        #expect(second.connection.paramsForMethod("events.unsubscribe").isEmpty)
        #expect(modelB.hookStore.hooks.count == 1 && modelB.monitoredPrStore.monitors.count == 1)
    }
}

extension SharedWorkspaceStatusLifetimeTests {
    @Test func queuedWorkspaceCleanupPreservesOtherWorkspaceAndGlobalMonitor() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let connection = fixture.connection
        connection.releaseConnectionStateDelivery()
        let owner = UUID()
        let otherWorkspace = "other-workspace"
        for workspace in [Support.workspace, otherWorkspace] {
            fixture.session.retainWorkspaceStatus(workspaceId: workspace, consumer: owner)
            await fixture.session.hooksStore.load(workspaceId: workspace)
            await fixture.session.prMonitorsStore.seed(workspaceId: workspace)
        }
        let ids = try Support.acknowledgedIDs(connection)
        #expect(ids.count == 3)
        let releasedHook = try #require(fixture.session.hooksStore.feeds[Support.workspace]?.id)
        let otherHook = fixture.session.hooksStore.feeds[otherWorkspace]?.id
        let globalMonitor = fixture.session.prMonitorsStore.cache.feeds[""]?.id
        let checkpoint = connection.checkpoint
        fixture.session.releaseWorkspaceStatus(workspaceId: Support.workspace, consumer: owner)
        await fixture.session.hooksStore.load(workspaceId: otherWorkspace)
        await fixture.session.prMonitorsStore.seed(workspaceId: otherWorkspace)
        try await Support.waitForCleanup(connection, events: [releasedHook], chats: 0)
        #expect(connection.traffic(since: checkpoint).methodCounts == ["events.unsubscribe": 1])
        #expect(fixture.session.hooksStore.feeds[otherWorkspace]?.id == otherHook)
        #expect(fixture.session.prMonitorsStore.cache.feeds[""]?.id == globalMonitor)
        fixture.session.releaseWorkspaceStatus(workspaceId: otherWorkspace, consumer: owner)
        try await Support.waitForCleanup(connection, events: ids, chats: 0)
    }

    @Test(arguments: [false, true])
    func queuedResetCleanupUsesOnlyTheRegistrationSocket(reconnect: Bool) async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let connection = fixture.connection
        connection.releaseConnectionStateDelivery()
        let model = fixture.makeViewModel()
        await model.load()
        let oldIDs = try Support.acknowledgedIDs(connection)
        #expect(oldIDs.count == 2)
        fixture.session.hooksStore.reset()
        fixture.session.prMonitorsStore.reset()
        if reconnect {
            connection.simulateDisconnect()
            connection.simulateConnect()
        }
        if reconnect {
            try await expectNever("reset releases an old socket's registration") {
                !connection.paramsForMethod("events.unsubscribe").isEmpty
            }
        } else {
            try await Support.waitForCleanup(connection, events: oldIDs, chats: 0)
        }
        #expect(fixture.session.hooksStore.buckets.isEmpty)
        #expect(fixture.session.prMonitorsStore.cache.buckets.isEmpty)
    }

    @Test(arguments: [false, true])
    func queuedDeinitCleanupKeepsConnectionProvenanceAfterStoreDies(reconnect: Bool) async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let connection = fixture.connection
        connection.releaseConnectionStateDelivery()
        var hooks: WorkspaceStatusStore<BackgroundHook>? = BackgroundHookStore.makeWorkspaceStore(connection: connection)
        var monitors: WorkspacePrMonitorsStore? = WorkspacePrMonitorsStore(connectionManager: connection)
        weak var weakHooks = hooks
        weak var weakMonitors = monitors?.cache
        weak var hookLifetime = hooks?.connectionLifetime
        weak var monitorLifetime = monitors?.cache.connectionLifetime
        hooks?.retain(workspaceId: Support.workspace)
        monitors?.retain(workspaceId: Support.workspace)
        await hooks?.load(workspaceId: Support.workspace)
        await monitors?.seed(workspaceId: Support.workspace)
        let ids = try Support.acknowledgedIDs(connection)
        #expect(ids.count == 2)
        hooks = nil
        monitors = nil
        #expect(weakHooks == nil && weakMonitors == nil)
        if reconnect {
            connection.simulateDisconnect()
            connection.simulateConnect()
            try await expectNever("deinit releases an old socket's registration") {
                !connection.paramsForMethod("events.unsubscribe").isEmpty
            }
        } else {
            try await Support.waitForCleanup(connection, events: ids, chats: 0)
        }
        try await waitUntil("connection observers released with cleanup") {
            hookLifetime == nil && monitorLifetime == nil
        }
    }

    @Test(arguments: [false, true])
    func queuedOrphanCleanupChecksConnectionWhenItStarts(reconnect: Bool) async {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let connection = fixture.connection
        connection.releaseConnectionStateDelivery()
        // Exercise the deferred helper used after a late ACK independently of
        // whether the ACK continuation or the caller resumes first.
        let source = fixture.session.hooksStore
        let cleanup = WorkspaceStatusStore<BackgroundHook>.releaseRemote(
            "orphan", connection: connection, lifetime: source.connectionLifetime, epoch: source.connectionEpoch
        )
        if reconnect {
            connection.simulateDisconnect()
            connection.simulateConnect()
        }
        await cleanup.value
        let releases = connection.traffic().calls("events.unsubscribe")
        #expect(releases.count == (reconnect ? 0 : 1))
        if let release = releases.first {
            #expect(release.params["subscriptionId"] as? String == "orphan")
            #expect(release.started.connectionGeneration == 1)
        }
    }
}
