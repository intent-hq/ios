import Foundation
import Testing
@testable import Intent

@MainActor
struct MonitoredPrStoreTests {

    /// The full §5.42 `prMonitor.list` sample row from PROTOCOL.md.
    private func makeMonitorDict(
        monitorId: String = "prm-1",
        state: String = "active"
    ) -> [String: Any] {
        [
            "monitorId": monitorId,
            "workspaceId": "ws-abc",
            "agentId": "agent-1",
            "repo": "octo/repo",
            "prNumber": 12,
            "state": state,
            "pendingChanges": ["check ci: pending → failed"],
            "hasPendingChanges": true,
            "pendingSince": "2026-08-07T12:00:00.000Z",
            "lastChangeAt": "2026-08-07T12:00:00.000Z",
            "lastPolledAt": "2026-08-07T12:00:30.000Z",
            "title": "Add review wire surface",
            "url": "https://github.com/octo/repo/pull/12",
            "lastSnapshot": [
                "state": "open", "isDraft": false, "hasConflicts": false, "isBehind": false,
                "mergeable": true, "mergeBlockedReason": "1 required check failing (ci)",
                "checks": ["total": 3, "passed": 2, "failed": 1, "pending": 0,
                           "failingRequired": ["ci"], "pendingRequired": [] as [String],
                           "requiredKnown": true],
                "approvals": ["decision": "approved", "have": 1, "needed": 1,
                              "changesRequested": 0],
                "threads": ["unresolved": 0, "resolutionRequired": true],
                "rulesKnown": true
            ] as [String: Any],
            "createdAt": "2026-08-07T11:58:00.000Z",
            "updatedAt": "2026-08-07T12:00:30.000Z"
        ]
    }

    /// A minimal wire row: only the always-present fields (a monitor that
    /// has no successful poll baseline yet).
    private func makeMinimalMonitorDict() -> [String: Any] {
        [
            "monitorId": "prm-2",
            "workspaceId": "ws-abc",
            "agentId": "agent-1",
            "repo": "octo/repo",
            "prNumber": 34,
            "state": "active",
            "pendingChanges": [] as [String],
            "hasPendingChanges": false,
            "createdAt": "2026-08-07T11:58:00.000Z",
            "updatedAt": "2026-08-07T11:58:00.000Z"
        ]
    }

    // MARK: - Model parsing

    @Test func parsesFullProtocolSample() throws {
        let monitor = try #require(MonitoredPr.parseMonitor(makeMonitorDict()))
        #expect(monitor.monitorId == "prm-1")
        #expect(monitor.workspaceId == "ws-abc")
        #expect(monitor.agentId == "agent-1")
        #expect(monitor.repo == "octo/repo")
        #expect(monitor.prNumber == 12)
        #expect(monitor.state == .active)
        #expect(monitor.pendingChanges == ["check ci: pending → failed"])
        #expect(monitor.hasPendingChanges == true)
        #expect(monitor.pendingSince == "2026-08-07T12:00:00.000Z")
        #expect(monitor.lastChangeAt == "2026-08-07T12:00:00.000Z")
        #expect(monitor.lastPolledAt == "2026-08-07T12:00:30.000Z")
        #expect(monitor.lastError == nil)
        #expect(monitor.title == "Add review wire surface")
        #expect(monitor.url == "https://github.com/octo/repo/pull/12")
        #expect(monitor.createdAt == "2026-08-07T11:58:00.000Z")
        #expect(monitor.updatedAt == "2026-08-07T12:00:30.000Z")

        let snapshot = try #require(monitor.lastSnapshot)
        #expect(snapshot.state == "open")
        #expect(snapshot.isDraft == false)
        #expect(snapshot.hasConflicts == false)
        #expect(snapshot.isBehind == false)
        #expect(snapshot.mergeable == true)
        #expect(snapshot.mergeBlockedReason == "1 required check failing (ci)")
        #expect(snapshot.checks == .init(total: 3, passed: 2, failed: 1, pending: 0))
        #expect(snapshot.approvals == .init(decision: "approved", have: 1,
                                            needed: 1, changesRequested: 0))
        #expect(snapshot.threads == .init(unresolved: 0))
    }

    @Test func parsesLastErrorWhenPresent() throws {
        var dict = makeMonitorDict()
        dict["lastError"] = "GitHub API rate limit exceeded"
        let monitor = try #require(MonitoredPr.parseMonitor(dict))
        #expect(monitor.lastError == "GitHub API rate limit exceeded")
    }

    @Test func parsesMinimalRowWithPresenceDetectedNils() throws {
        let monitor = try #require(MonitoredPr.parseMonitor(makeMinimalMonitorDict()))
        #expect(monitor.pendingChanges.isEmpty)
        #expect(monitor.hasPendingChanges == false)
        #expect(monitor.pendingSince == nil)
        #expect(monitor.lastChangeAt == nil)
        #expect(monitor.lastPolledAt == nil)
        #expect(monitor.lastError == nil)
        #expect(monitor.title == nil)
        #expect(monitor.url == nil)
        #expect(monitor.lastSnapshot == nil)
    }

    @Test func parsesSnapshotOptionalFieldsAsNilWhenAbsent() throws {
        var dict = makeMonitorDict()
        // A degraded snapshot: `mergeable` still computing,
        // no blocked reason, unreadable branch rules (needed omitted).
        dict["lastSnapshot"] = [
            "state": "open", "isDraft": true, "hasConflicts": true, "isBehind": true,
            "checks": ["total": 0, "passed": 0, "failed": 0, "pending": 0],
            "approvals": ["decision": "review_required", "have": 0, "changesRequested": 2],
            "threads": ["unresolved": 3]
        ] as [String: Any]
        let monitor = try #require(MonitoredPr.parseMonitor(dict))
        let snapshot = try #require(monitor.lastSnapshot)
        #expect(snapshot.mergeable == nil)
        #expect(snapshot.mergeBlockedReason == nil)
        #expect(snapshot.isDraft == true)
        #expect(snapshot.hasConflicts == true)
        #expect(snapshot.isBehind == true)
        #expect(snapshot.approvals == .init(decision: "review_required", have: 0,
                                            needed: nil, changesRequested: 2))
        #expect(snapshot.threads == .init(unresolved: 3))
    }

    @Test func parsesAllStatesAndIsActive() throws {
        let expectations: [(String, MonitoredPr.State, Bool)] = [
            ("active", .active, true),
            ("completed", .completed, false),
            ("cancelled", .cancelled, false)
        ]
        for (raw, expected, active) in expectations {
            let monitor = try #require(MonitoredPr.parseMonitor(makeMonitorDict(state: raw)))
            #expect(monitor.state == expected)
            #expect(monitor.isActive == active)
        }
    }

    @Test func rejectsMissingRequiredOrUnknownState() {
        var missingId = makeMonitorDict()
        missingId.removeValue(forKey: "monitorId")
        #expect(MonitoredPr.parseMonitor(missingId) == nil)
        var missingRepo = makeMonitorDict()
        missingRepo.removeValue(forKey: "repo")
        #expect(MonitoredPr.parseMonitor(missingRepo) == nil)
        var missingPrNumber = makeMonitorDict()
        missingPrNumber.removeValue(forKey: "prNumber")
        #expect(MonitoredPr.parseMonitor(missingPrNumber) == nil)
        #expect(MonitoredPr.parseMonitor(makeMonitorDict(state: "someFutureState")) == nil)
    }

    // MARK: - Fold

    /// The canonical §6.5 `prMonitor:*` event data payload.
    private func makeEventData(
        monitorId: String = "prm-1",
        state: String = "active",
        changes: [String]? = nil
    ) -> [String: Any] {
        var data: [String: Any] = [
            "workspaceId": "ws-abc",
            "agentId": "agent-1",
            "monitorId": monitorId,
            "repo": "octo/repo",
            "prNumber": 12,
            "state": state
        ]
        if let changes { data["changes"] = changes }
        return data
    }

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
            data: makeEventData(monitorId: "prm-2",
                                changes: ["check ci: pending → failed", "1 new comment"])
        )
        #expect(result.monitors[0].pendingChanges == ["check ci: pending → failed",
                                                      "1 new comment"])
        #expect(result.monitors[0].hasPendingChanges == true)
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

    @Test func foldUnknownMonitorRequestsRefetch() throws {
        for eventType in ["prMonitor:registered", "prMonitor:changed",
                          "prMonitor:emitted", "prMonitor:completed"] {
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
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(store.monitors[0].state == .completed)
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
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(store.monitors.count == 1)
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
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(fake.paramsForMethod("prMonitor.list").count == 1)
        #expect(store.monitors.count == 1)
        #expect(store.monitors[0].monitorId == "prm-new")
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
        let cancelParams = try #require(fake.paramsForMethod("prMonitor.cancel").first)
        #expect(cancelParams["workspaceId"] as? String == "ws-abc")
        #expect(cancelParams["monitorId"] as? String == "prm-1")
    }

    @Test func reconnectResubscribesAndReseeds() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSubscribedStore(fake, monitors: [makeMonitorDict()])
        fake.clearRequestLog()

        fake.simulateDisconnect()
        fake.simulateConnect()
        await Task.yield()
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if fake.didCallMethod("prMonitor.list") { break }
        }

        #expect(fake.didCallMethod("events.subscribe"))
        #expect(fake.didCallMethod("prMonitor.list"))
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
        try await Task.sleep(nanoseconds: 20_000_000)

        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": "sub-prmon",
            "event": [
                "type": "prMonitor:cancelled",
                "workspaceId": "ws-abc",
                "data": makeEventData(state: "cancelled")
            ]
        ] as [String: Any])
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(store.monitors.isEmpty)

        // Resolve the in-flight request with the STALE payload — it still
        // lists the cancelled monitor. The queued follow-up stays suspended,
        // so a wrongly applied stale response cannot be masked by
        // convergence.
        fake.resolvePending("prMonitor.list", with: ["monitors": [makeMonitorDict()]])
        try await Task.sleep(nanoseconds: 20_000_000)

        // The stale response must not restore the cancelled monitor; the
        // discarded response queues one follow-up fetch to converge.
        #expect(store.monitors.isEmpty)
        #expect(fake.paramsForMethod("prMonitor.list").count == 2)

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
        try await Task.sleep(nanoseconds: 20_000_000)

        await store.unsubscribe()
        #expect(store.monitors.isEmpty)

        await refetchTask.value

        // The stale response must not repopulate the cleared list, and the
        // queued follow-up bails out (no workspace bound anymore).
        #expect(store.monitors.isEmpty)
        #expect(fake.paramsForMethod("prMonitor.list").count == 1)
    }
}
