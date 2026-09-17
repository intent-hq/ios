import Foundation
@testable import Intent
import Testing

@MainActor
struct BackgroundHookStoreTests {
    private struct HookStateExpectation {
        let rawValue: String
        let state: BackgroundHook.State
        let isActive: Bool
    }

    private enum PerpetualFixtureState {
        case oneShot
        case perpetual
        case unreported
    }

    private func makeHookDict(
        hookId: String = "hook-1",
        state: String = "scheduled",
        nextRunAt: String? = "2026-07-31T10:06:00Z",
        perpetual: PerpetualFixtureState = .unreported
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "hookId": hookId,
            "workspaceId": "ws-1",
            "agentId": "agent-1",
            "name": "ci-watch",
            "code": "const s = await ws.pr.status();",
            "delayMs": 60_000,
            "state": state,
            "createdAt": "2026-07-31T10:00:00Z",
            "expiresAt": "2026-07-31T11:00:00Z",
            "runCount": 6
        ]
        if let nextRunAt { dict["nextRunAt"] = nextRunAt }
        switch perpetual {
        case .oneShot: dict["perpetual"] = false
        case .perpetual: dict["perpetual"] = true
        case .unreported: break
        }
        return dict
    }

    // MARK: - Model parsing

    @Test func parsesFullHook() throws {
        let hook = try #require(BackgroundHook.parseHook(makeHookDict()))
        #expect(hook.hookId == "hook-1")
        #expect(hook.workspaceId == "ws-1")
        #expect(hook.agentId == "agent-1")
        #expect(hook.name == "ci-watch")
        #expect(hook.code == "const s = await ws.pr.status();")
        #expect(hook.delayMs == 60_000)
        #expect(hook.state == .scheduled)
        #expect(hook.createdAt == "2026-07-31T10:00:00Z")
        #expect(hook.expiresAt == "2026-07-31T11:00:00Z")
        #expect(hook.nextRunAt == "2026-07-31T10:06:00Z")
        #expect(hook.runCount == 6)
        #expect(hook.perpetual == false)
        #expect(hook.lastError == nil)
    }

    @Test func parsesPerpetualFlag() throws {
        let perpetual = try #require(BackgroundHook.parseHook(makeHookDict(perpetual: .perpetual)))
        #expect(perpetual.perpetual == true)
        let oneShot = try #require(BackgroundHook.parseHook(makeHookDict(perpetual: .oneShot)))
        #expect(oneShot.perpetual == false)
    }

    @Test func parsesAllStatesAndIsActive() throws {
        let expectations = [
            HookStateExpectation(rawValue: "scheduled", state: .scheduled, isActive: true),
            HookStateExpectation(rawValue: "running", state: .running, isActive: true),
            HookStateExpectation(rawValue: "dispatched", state: .dispatched, isActive: false),
            HookStateExpectation(rawValue: "evicted", state: .evicted, isActive: false),
            HookStateExpectation(rawValue: "cancelled", state: .cancelled, isActive: false),
            HookStateExpectation(rawValue: "expired", state: .expired, isActive: false)
        ]
        for expectation in expectations {
            let hook = try #require(BackgroundHook.parseHook(makeHookDict(state: expectation.rawValue)))
            #expect(hook.state == expectation.state)
            #expect(hook.isActive == expectation.isActive)
        }
    }

    @Test func rejectsMissingRequiredOrUnknownState() {
        var missingId = makeHookDict()
        missingId.removeValue(forKey: "hookId")
        #expect(BackgroundHook.parseHook(missingId) == nil)
        #expect(BackgroundHook.parseHook(makeHookDict(state: "someFutureState")) == nil)
    }

    // MARK: - Detail lines (BackgroundHooksRow pure helpers)

    @Test func detailLinesShowTimingRelativeToNow() throws {
        let hook = try #require(BackgroundHook.parseHook(makeHookDict()))
        let now = try #require(ISO8601DateFormatter.lenientDate(from: "2026-07-31T10:05:15Z"))
        #expect(BackgroundHooksRow.detailLines(hook, now: now) == [
            "ci-watch — Scheduled",
            "Next run: in 45s",
            "TTL: expires in 54m 45s"
        ])
    }

    @Test func detailLinesDropAbsentTimingAndShowLastError() throws {
        var dict = makeHookDict(state: "running", nextRunAt: nil)
        dict.removeValue(forKey: "expiresAt")
        dict["lastError"] = "boom"
        let hook = try #require(BackgroundHook.parseHook(dict))
        #expect(BackgroundHooksRow.detailLines(hook) == [
            "ci-watch — Running",
            "Last error: boom"
        ])
    }

    @Test func compactDurationRendersTwoAdjacentUnitsAndClamps() {
        #expect(DurationFormat.compact(-5) == "0s")
        #expect(DurationFormat.compact(42) == "42s")
        #expect(DurationFormat.compact(59.6) == "1m")
        #expect(DurationFormat.compact(12 * 60) == "12m")
        #expect(DurationFormat.compact(12 * 60 + 30) == "12m 30s")
        #expect(DurationFormat.compact(3600) == "1h")
        #expect(DurationFormat.compact(3600 + 5 * 60 + 30) == "1h 5m")
        #expect(DurationFormat.compact(3600 + 30) == "1h")
        #expect(DurationFormat.compact(2 * 86_400 + 3 * 3600) == "2d 3h")
        #expect(DurationFormat.compact(86_400 + 30 * 60) == "1d")
    }

    // MARK: - Fold

    @Test func foldRunStartedSetsRunning() throws {
        let hook = try #require(BackgroundHook.parseHook(makeHookDict()))
        let result = BackgroundHookStore.foldHookEvent(
            hooks: [hook],
            eventType: "hook:run-started",
            data: ["hookId": "hook-1"]
        )
        #expect(result.hooks[0].state == .running)
        #expect(result.needsRefetch == false)
    }

    @Test func foldRunCompletedReplacesNextRunAt() throws {
        let hook = try #require(BackgroundHook.parseHook(makeHookDict(state: "running")))
        let result = BackgroundHookStore.foldHookEvent(
            hooks: [hook],
            eventType: "hook:run-completed",
            data: ["hookId": "hook-1", "nextRunAt": "2026-07-31T10:07:00Z"]
        )
        #expect(result.hooks[0].state == .scheduled)
        #expect(result.hooks[0].nextRunAt == "2026-07-31T10:07:00Z")
        // Absent nextRunAt clears it (a terminal event follows)
        let cleared = BackgroundHookStore.foldHookEvent(
            hooks: [hook],
            eventType: "hook:run-completed",
            data: ["hookId": "hook-1"]
        )
        #expect(cleared.hooks[0].nextRunAt == nil)
    }

    @Test func foldScheduledKeepsExistingNextRunAtWhenAbsent() throws {
        let hook = try #require(BackgroundHook.parseHook(makeHookDict()))
        let result = BackgroundHookStore.foldHookEvent(
            hooks: [hook],
            eventType: "hook:scheduled",
            data: ["hookId": "hook-1"]
        )
        #expect(result.hooks[0].nextRunAt == "2026-07-31T10:06:00Z")
    }

    @Test func foldTerminalEventsRemoveHook() throws {
        let hook = try #require(BackgroundHook.parseHook(makeHookDict()))
        for eventType in ["hook:dispatched", "hook:evicted", "hook:cancelled", "hook:expired"] {
            let result = BackgroundHookStore.foldHookEvent(
                hooks: [hook],
                eventType: eventType,
                data: ["hookId": "hook-1"]
            )
            #expect(result.hooks.isEmpty)
            #expect(result.needsRefetch == false)
        }
    }

    @Test func foldUnknownHookRequestsRefetch() {
        let result = BackgroundHookStore.foldHookEvent(
            hooks: [],
            eventType: "hook:scheduled",
            data: ["hookId": "hook-new"]
        )
        #expect(result.hooks.isEmpty)
        #expect(result.needsRefetch == true)
    }

    @Test func foldRetainsCodeFromList() throws {
        let hook = try #require(BackgroundHook.parseHook(makeHookDict()))
        let result = BackgroundHookStore.foldHookEvent(
            hooks: [hook],
            eventType: "hook:run-started",
            data: ["hookId": "hook-1", "name": "ci-watch", "state": "running"]
        )
        #expect(result.hooks[0].code == "const s = await ws.pr.status();")
    }
}

extension BackgroundHookStoreTests {
    // MARK: - Store integration (subscribe / events / RPC / reconnect)

    private func makeSubscribedStore(
        _ fake: FakeConnectionManager,
        hooks: [[String: Any]] = []
    ) async -> BackgroundHookStore {
        fake.responseMap["events.subscribe"] = ["subscriptionId": "sub-hooks"]
        fake.responseMap["events.unsubscribe"] = [:] as [String: Any]
        fake.responseMap["hook.list"] = ["hooks": hooks]
        let store = BackgroundHookStore(connectionManager: fake)
        await store.subscribe(workspaceId: "ws-1", agentId: "agent-1")
        return store
    }

    @Test func subscribeRegistersHookFilterAndSeeds() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSubscribedStore(fake, hooks: [makeHookDict()])

        let subscribeParams = try #require(fake.paramsForMethod("events.subscribe").first)
        #expect(subscribeParams["eventTypes"] as? [String] == ["hook:*"])
        #expect(subscribeParams["workspaceId"] as? String == "ws-1")
        #expect(subscribeParams["replaceGroup"] as? String == "ios-hooks-ws-1-agent-1")
        #expect(fake.paramsForMethod("hook.list").first?["workspaceId"] as? String == "ws-1")
        #expect(store.hooks.count == 1)
        #expect(store.activeHooks.count == 1)
    }

    @Test func wrappedEventFoldsIntoList() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSubscribedStore(fake, hooks: [makeHookDict()])

        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": "sub-hooks",
            "event": [
                "type": "hook:run-started",
                "workspaceId": "ws-1",
                "data": [
                    "workspaceId": "ws-1",
                    "agentId": "agent-1",
                    "hookId": "hook-1",
                    "name": "ci-watch",
                    "state": "running"
                ]
            ]
        ] as [String: Any])
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(store.hooks[0].state == .running)
        #expect(store.hooks[0].code == "const s = await ws.pr.status();")
    }

    @Test func ignoresForeignWorkspaceAndForeignSubscription() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSubscribedStore(fake, hooks: [makeHookDict()])

        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": "sub-hooks",
            "event": [
                "type": "hook:cancelled",
                "workspaceId": "ws-other",
                "data": ["workspaceId": "ws-other", "hookId": "hook-1"]
            ]
        ] as [String: Any])
        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": "sub-foreign",
            "event": [
                "type": "hook:cancelled",
                "workspaceId": "ws-1",
                "data": ["workspaceId": "ws-1", "hookId": "hook-1"]
            ]
        ] as [String: Any])
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(store.hooks.count == 1)
    }

    @Test func unknownHookEventTriggersRefetch() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSubscribedStore(fake)
        fake.clearRequestLog()
        fake.responseMap["hook.list"] = ["hooks": [makeHookDict(hookId: "hook-new")]]

        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": "sub-hooks",
            "event": [
                "type": "hook:scheduled",
                "workspaceId": "ws-1",
                "data": ["workspaceId": "ws-1", "hookId": "hook-new"]
            ]
        ] as [String: Any])
        try await Task.sleep(nanoseconds: 100_000_000)

        #expect(fake.paramsForMethod("hook.list").count == 1)
        #expect(store.hooks.count == 1)
        #expect(store.hooks[0].hookId == "hook-new")
    }

    @Test func runNowAndCancelSendExactParams() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSubscribedStore(fake)
        fake.responseMap["hook.runNow"] = ["ok": true, "hookId": "hook-1"]
        fake.responseMap["hook.cancel"] = ["ok": true]

        await store.runNow(hookId: "hook-1")
        await store.cancel(hookId: "hook-1")

        let runParams = try #require(fake.paramsForMethod("hook.runNow").first)
        #expect(runParams["workspaceId"] as? String == "ws-1")
        #expect(runParams["hookId"] as? String == "hook-1")
        let cancelParams = try #require(fake.paramsForMethod("hook.cancel").first)
        #expect(cancelParams["workspaceId"] as? String == "ws-1")
        #expect(cancelParams["hookId"] as? String == "hook-1")
    }

    @Test func reconnectResubscribesAndReseeds() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSubscribedStore(fake, hooks: [makeHookDict()])
        fake.clearRequestLog()

        fake.simulateDisconnect()
        fake.simulateConnect()
        await Task.yield()
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000)
            if fake.didCallMethod("hook.list") { break }
        }

        #expect(fake.didCallMethod("events.subscribe"))
        #expect(fake.didCallMethod("hook.list"))
        #expect(store.hooks.count == 1)
    }

    @Test func unsubscribeClearsStateAndReleasesSubscription() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSubscribedStore(fake, hooks: [makeHookDict()])

        await store.unsubscribe()

        let unsubParams = try #require(fake.paramsForMethod("events.unsubscribe").first)
        #expect(unsubParams["subscriptionId"] as? String == "sub-hooks")
        #expect(store.hooks.isEmpty)
        #expect(fake.eventHandlerCount == 0)
    }

    @Test func staleListResponseAfterCancelledFoldIsDiscarded() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSubscribedStore(fake, hooks: [makeHookDict()])
        fake.clearRequestLog()

        // Suspend hook.list requests so a fold can land while one is in flight.
        fake.pendingMethods.insert("hook.list")
        let refetchTask = Task { await store.refetch() }
        try await Task.sleep(nanoseconds: 20_000_000)

        fake.deliverEvent(method: "events.event", params: [
            "subscriptionId": "sub-hooks",
            "event": [
                "type": "hook:cancelled",
                "workspaceId": "ws-1",
                "data": ["workspaceId": "ws-1", "hookId": "hook-1"]
            ]
        ] as [String: Any])
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(store.hooks.isEmpty)

        // Resolve the in-flight request with the STALE payload — it still
        // lists the cancelled hook. The queued follow-up stays suspended, so
        // a wrongly applied stale response cannot be masked by convergence.
        fake.resolvePending("hook.list", with: ["hooks": [makeHookDict()]])
        try await Task.sleep(nanoseconds: 20_000_000)

        // The stale response must not restore the cancelled hook; the
        // discarded response queues one follow-up fetch to converge.
        #expect(store.hooks.isEmpty)
        #expect(fake.paramsForMethod("hook.list").count == 2)

        // Fresh server state (post-cancel) for the queued follow-up fetch.
        fake.resolvePending("hook.list", with: ["hooks": [] as [[String: Any]]])
        await refetchTask.value
        #expect(store.hooks.isEmpty)
    }

    @Test func staleListResponseAfterUnsubscribeIsDiscarded() async throws {
        let fake = FakeConnectionManager()
        let store = await makeSubscribedStore(fake, hooks: [makeHookDict()])
        fake.clearRequestLog()

        fake.delayMap["hook.list"] = 100_000_000
        let refetchTask = Task { await store.refetch() }
        try await Task.sleep(nanoseconds: 20_000_000)

        await store.unsubscribe()
        #expect(store.hooks.isEmpty)

        await refetchTask.value

        // The stale response must not repopulate the cleared list, and the
        // queued follow-up bails out (no workspace bound anymore).
        #expect(store.hooks.isEmpty)
        #expect(fake.paramsForMethod("hook.list").count == 1)
    }

    // MARK: - deinit removes event handler (monorepo#2211)

    @Test func deinitRemovesEventHandler() async throws {
        let fake = FakeConnectionManager()
        var store: BackgroundHookStore? = await makeSubscribedStore(fake)
        #expect(fake.eventHandlerCount == 1)
        #expect(store != nil)

        store = nil
        // deinit hops to the main actor to remove the handler; wait for that task
        for _ in 0..<40 {
            if fake.eventHandlerCount == 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(fake.eventHandlerCount == 0)
    }
}
