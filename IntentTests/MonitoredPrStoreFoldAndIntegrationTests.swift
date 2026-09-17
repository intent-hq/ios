import Foundation
@testable import Intent
import Testing

extension MonitoredPrStoreTests {
    // MARK: - Fold

    @Test func foldRegisteredSetsActive() throws {
        let monitor = try #require(MonitoredPr.parseMonitor(makeMonitorDict(state: "completed")))
        let result = MonitoredPrStore.foldMonitorEvent(
            monitors: [monitor],
            eventType: "prMonitor:registered",
            data: makeEventData(state: "active")
        )
        #expect(result.monitors[0].state == .active)
    }

    @Test func foldRegisteredReArmClearsPendingStateAndRefetches() throws {
        // A re-arm refreshes the baseline server-side (§5.42): the fold
        // must not leave pre-re-arm pending state visible, and must refetch
        // to converge on the refreshed row.
        let monitor = try #require(MonitoredPr.parseMonitor(makeMonitorDict()))
        #expect(monitor.hasPendingChanges == true)
        let result = MonitoredPrStore.foldMonitorEvent(
            monitors: [monitor],
            eventType: "prMonitor:registered",
            data: makeEventData(state: "active")
        )
        #expect(result.monitors[0].pendingChanges.isEmpty)
        #expect(result.monitors[0].hasPendingChanges == false)
        #expect(result.monitors[0].pendingSince == nil)
        #expect(result.needsRefetch == true)
    }

    @Test func foldChangedReplacesPendingChanges() throws {
        let monitor = try #require(MonitoredPr.parseMonitor(makeMinimalMonitorDict()))
        let result = MonitoredPrStore.foldMonitorEvent(
            monitors: [monitor],
            eventType: "prMonitor:changed",
            data: makeEventData(
                monitorId: "prm-2",
                changes: ["check ci: pending → failed", "1 new comment"]
            )
        )
        #expect(result.monitors[0].pendingChanges == [
            "check ci: pending → failed",
            "1 new comment"
        ])
        #expect(result.monitors[0].hasPendingChanges == true)
        #expect(result.needsRefetch == false)
    }

    @Test func foldChangedWithoutChangesPreservesPendingState() throws {
        let monitor = try #require(MonitoredPr.parseMonitor(makeMonitorDict()))
        let result = MonitoredPrStore.foldMonitorEvent(
            monitors: [monitor],
            eventType: "prMonitor:changed",
            data: makeEventData()
        )

        #expect(result.monitors[0].pendingChanges == monitor.pendingChanges)
        #expect(result.monitors[0].hasPendingChanges == monitor.hasPendingChanges)
        #expect(result.monitors[0].pendingSince == monitor.pendingSince)
        #expect(result.needsRefetch == false)
    }

    @Test func foldEmittedClearsPendingChanges() throws {
        let monitor = try #require(MonitoredPr.parseMonitor(makeMonitorDict()))
        let result = MonitoredPrStore.foldMonitorEvent(
            monitors: [monitor],
            eventType: "prMonitor:emitted",
            data: makeEventData()
        )
        #expect(result.monitors[0].pendingChanges.isEmpty)
        #expect(result.monitors[0].hasPendingChanges == false)
        #expect(result.monitors[0].pendingSince == nil)
        #expect(result.monitors[0].state == .active)
        #expect(result.needsRefetch == false)
    }

    @Test func foldCompletedRetainsMonitorAsCompleted() throws {
        let monitor = try #require(MonitoredPr.parseMonitor(makeMonitorDict()))
        let result = MonitoredPrStore.foldMonitorEvent(
            monitors: [monitor],
            eventType: "prMonitor:completed",
            data: makeEventData(state: "completed")
        )
        #expect(result.monitors.count == 1)
        #expect(result.monitors[0].state == .completed)
        #expect(result.monitors[0].hasPendingChanges == false)
        #expect(result.needsRefetch == false)
    }

    @Test func foldCancelledRemovesMonitor() throws {
        let monitor = try #require(MonitoredPr.parseMonitor(makeMonitorDict()))
        let result = MonitoredPrStore.foldMonitorEvent(
            monitors: [monitor],
            eventType: "prMonitor:cancelled",
            data: makeEventData(state: "cancelled")
        )
        #expect(result.monitors.isEmpty)
        #expect(result.needsRefetch == false)
    }

    @Test func foldUnknownMonitorRequestsRefetch() {
        for eventType in [
            "prMonitor:registered",
            "prMonitor:changed",
            "prMonitor:emitted",
            "prMonitor:completed"
        ] {
            let result = MonitoredPrStore.foldMonitorEvent(
                monitors: [],
                eventType: eventType,
                data: makeEventData(monitorId: "prm-new")
            )
            #expect(result.monitors.isEmpty)
            #expect(result.needsRefetch == true)
        }
        // Unknown + cancelled: nothing to drop, nothing to fetch
        let cancelled = MonitoredPrStore.foldMonitorEvent(
            monitors: [],
            eventType: "prMonitor:cancelled",
            data: makeEventData(monitorId: "prm-new")
        )
        #expect(cancelled.needsRefetch == false)
    }

    @Test func foldRetainsSnapshotFromList() throws {
        let monitor = try #require(MonitoredPr.parseMonitor(makeMonitorDict()))
        let result = MonitoredPrStore.foldMonitorEvent(
            monitors: [monitor],
            eventType: "prMonitor:changed",
            data: makeEventData(changes: ["new commit"])
        )
        #expect(result.monitors[0].lastSnapshot != nil)
        #expect(result.monitors[0].title == "Add review wire surface")
    }
}

extension MonitoredPrStoreTests {
    // MARK: - Store integration (subscribe / events / RPC / reconnect)

    private func makeSubscribedStore(
        _ fake: FakeConnectionManager,
        monitors: [[String: Any]] = []
    ) async -> MonitoredPrStore {
        fake.responseMap["events.subscribe"] = ["subscriptionId": "sub-prmon"]
        fake.responseMap["events.unsubscribe"] = [:] as [String: Any]
        fake.responseMap["prMonitor.list"] = ["monitors": monitors]
        let store = MonitoredPrStore(connectionManager: fake)
        await store.subscribe(workspaceId: "ws-abc", agentId: "agent-1")
        return store
    }

    @Test func subscribeRegistersPrMonitorFilterAndSeeds() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSubscribedStore(fake, monitors: [makeMonitorDict()])

        let subscribeParams = try #require(fake.paramsForMethod("events.subscribe").first)
        #expect(subscribeParams["eventTypes"] as? [String] == ["prMonitor:*"])
        #expect(subscribeParams["workspaceId"] as? String == "ws-abc")
        #expect(subscribeParams["replaceGroup"] as? String == "ios-pr-monitors-ws-abc-agent-1")
        #expect(fake.paramsForMethod("prMonitor.list").first?["workspaceId"] as? String == "ws-abc")
        #expect(store.monitors.count == 1)
        #expect(store.activeMonitors.count == 1)
    }

    @Test func wrappedEventFoldsIntoList() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSubscribedStore(fake, monitors: [makeMonitorDict()])

        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": "sub-prmon",
            "event": [
                "type": "prMonitor:completed",
                "workspaceId": "ws-abc",
                "data": makeEventData(state: "completed")
            ]
        ] as [String: Any])
        try await waitUntil("prMonitor:completed fold") {
            store.monitors.first?.state == .completed
        }

        #expect(store.monitors[0].lastSnapshot != nil)
    }

    @Test func ignoresForeignWorkspaceAndForeignSubscription() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSubscribedStore(fake, monitors: [makeMonitorDict()])

        var foreignWsData = makeEventData(state: "cancelled")
        foreignWsData["workspaceId"] = "ws-other"
        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": "sub-prmon",
            "event": [
                "type": "prMonitor:cancelled",
                "workspaceId": "ws-other",
                "data": foreignWsData
            ]
        ] as [String: Any])
        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": "sub-foreign",
            "event": [
                "type": "prMonitor:cancelled",
                "workspaceId": "ws-abc",
                "data": makeEventData(state: "cancelled")
            ]
        ] as [String: Any])
        try await expectNever("fold of a foreign-workspace or foreign-subscription event") {
            store.monitors.count != 1
        }
    }

    @Test func unknownMonitorEventTriggersRefetch() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSubscribedStore(fake)
        fake.clearRequestLog()
        fake.responseMap["prMonitor.list"] = ["monitors": [makeMonitorDict(monitorId: "prm-new")]]

        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": "sub-prmon",
            "event": [
                "type": "prMonitor:registered",
                "workspaceId": "ws-abc",
                "data": makeEventData(monitorId: "prm-new")
            ]
        ] as [String: Any])
        try await waitUntil("prMonitor.list refetch for the unknown monitor") {
            store.monitors.map(\.monitorId) == ["prm-new"]
        }

        #expect(fake.paramsForMethod("prMonitor.list").count == 1)
    }

    @Test func flushAndCancelSendExactParams() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSubscribedStore(fake)
        fake.responseMap["prMonitor.flush"] = ["ok": true, "flushed": true]
        fake.responseMap["prMonitor.cancel"] = ["ok": true]

        await store.flush(monitorId: "prm-1")
        await store.cancel(monitorId: "prm-1")

        let flushParams = try #require(fake.paramsForMethod("prMonitor.flush").first)
        #expect(flushParams["workspaceId"] as? String == "ws-abc")
        #expect(flushParams["monitorId"] as? String == "prm-1")
        // `check` nil must omit the key entirely (presence-detection
        // convention — wire-compatible with pre-check daemons).
        #expect(flushParams["check"] == nil)
        let cancelParams = try #require(fake.paramsForMethod("prMonitor.cancel").first)
        #expect(cancelParams["workspaceId"] as? String == "ws-abc")
        #expect(cancelParams["monitorId"] as? String == "prm-1")
    }

    @Test func flushWithCheckSendsCheckTrue() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSubscribedStore(fake)
        fake.responseMap["prMonitor.flush"] = ["ok": true, "flushed": true]

        await store.flush(monitorId: "prm-1", mode: .refreshFirst)

        let flushParams = try #require(fake.paramsForMethod("prMonitor.flush").first)
        #expect(flushParams["workspaceId"] as? String == "ws-abc")
        #expect(flushParams["monitorId"] as? String == "prm-1")
        #expect(flushParams["check"] as? Bool == true)
    }

    @Test func reconnectResubscribesAndReseeds() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSubscribedStore(fake, monitors: [makeMonitorDict()])
        fake.clearRequestLog()

        fake.simulateDisconnect()
        fake.simulateConnect()
        try await fake.waitForRequests("prMonitor.list")

        #expect(fake.didCallMethod("events.subscribe"))
        #expect(store.monitors.count == 1)
    }

    @Test func unsubscribeClearsStateAndReleasesSubscription() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSubscribedStore(fake, monitors: [makeMonitorDict()])

        await store.unsubscribe()

        let unsubParams = try #require(fake.paramsForMethod("events.unsubscribe").first)
        #expect(unsubParams["subscriptionId"] as? String == "sub-prmon")
        #expect(store.monitors.isEmpty)
        #expect(fake.eventHandlerCount == 0)
    }

    @Test func staleListResponseAfterCancelledFoldIsDiscarded() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSubscribedStore(fake, monitors: [makeMonitorDict()])
        fake.clearRequestLog()

        // Suspend prMonitor.list requests so a fold can land while one is
        // in flight.
        fake.pendingMethods.insert("prMonitor.list")
        let refetchTask = Task { await store.refetch() }
        try await fake.waitForPendingRequests("prMonitor.list")

        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": "sub-prmon",
            "event": [
                "type": "prMonitor:cancelled",
                "workspaceId": "ws-abc",
                "data": makeEventData(state: "cancelled")
            ]
        ] as [String: Any])
        try await waitUntil("prMonitor:cancelled fold") { store.monitors.isEmpty }

        // Resolve the in-flight request with the STALE payload — it still
        // lists the cancelled monitor. The queued follow-up stays suspended,
        // so a wrongly applied stale response cannot be masked by
        // convergence.
        fake.resolvePending("prMonitor.list", with: ["monitors": [makeMonitorDict()]])
        // The discarded response queues one follow-up fetch to converge.
        try await fake.waitForRequests("prMonitor.list", count: 2)

        // The stale response must not restore the cancelled monitor.
        #expect(store.monitors.isEmpty)

        // Fresh server state (post-cancel) for the queued follow-up fetch.
        fake.resolvePending("prMonitor.list", with: ["monitors": [] as [[String: Any]]])
        await refetchTask.value
        #expect(store.monitors.isEmpty)
    }

    @Test func staleListResponseAfterUnsubscribeIsDiscarded() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSubscribedStore(fake, monitors: [makeMonitorDict()])
        fake.clearRequestLog()

        fake.delayMap["prMonitor.list"] = 100_000_000
        let refetchTask = Task { await store.refetch() }
        try await fake.waitForRequests("prMonitor.list")

        await store.unsubscribe()
        #expect(store.monitors.isEmpty)

        await refetchTask.value

        // The stale response must not repopulate the cleared list, and the
        // queued follow-up bails out (no workspace bound anymore).
        #expect(store.monitors.isEmpty)
        #expect(fake.paramsForMethod("prMonitor.list").count == 1)
    }

    // MARK: - deinit removes event handler (monorepo#2211)

    @Test func deinitRemovesEventHandler() async throws {
        let fake = FakeConnectionManager()
        var store: MonitoredPrStore? = await makeSubscribedStore(fake)
        #expect(fake.eventHandlerCount == 1)
        #expect(store != nil)

        store = nil
        try await waitUntil("deinit to remove the event handler") {
            fake.eventHandlerCount == 0
        }
    }
}
