import Foundation
import Testing
@testable import Intent

@MainActor
struct BackgroundHookStoreTests {

    private func makeHookDict(
        hookId: String = "hook-1",
        state: String = "scheduled",
        nextRunAt: String? = "2026-07-31T10:06:00Z"
    ) -> [String: Any] {
        var dict: [String: Any] = [
            "hookId": hookId,
            "workspaceId": "ws-1",
            "agentId": "agent-1",
            "name": "ci-watch",
            "code": "const s = await ws.pr.status();",
            "delayMs": 60000,
            "state": state,
            "createdAt": "2026-07-31T10:00:00Z",
            "expiresAt": "2026-07-31T11:00:00Z",
            "runCount": 6
        ]
        if let nextRunAt { dict["nextRunAt"] = nextRunAt }
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
        #expect(hook.delayMs == 60000)
        #expect(hook.state == .scheduled)
        #expect(hook.createdAt == "2026-07-31T10:00:00Z")
        #expect(hook.expiresAt == "2026-07-31T11:00:00Z")
        #expect(hook.nextRunAt == "2026-07-31T10:06:00Z")
        #expect(hook.runCount == 6)
        #expect(hook.lastError == nil)
    }

    @Test func parsesAllStatesAndIsActive() throws {
        let expectations: [(String, BackgroundHook.State, Bool)] = [
            ("scheduled", .scheduled, true),
            ("running", .running, true),
            ("dispatched", .dispatched, false),
            ("evicted", .evicted, false),
            ("cancelled", .cancelled, false),
            ("expired", .expired, false)
        ]
        for (raw, expected, active) in expectations {
            let hook = try #require(BackgroundHook.parseHook(makeHookDict(state: raw)))
            #expect(hook.state == expected)
            #expect(hook.isActive == active)
        }
    }

    @Test func rejectsMissingRequiredOrUnknownState() {
        var missingId = makeHookDict()
        missingId.removeValue(forKey: "hookId")
        #expect(BackgroundHook.parseHook(missingId) == nil)
        #expect(BackgroundHook.parseHook(makeHookDict(state: "someFutureState")) == nil)
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

    @Test func foldUnknownHookRequestsRefetch() throws {
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
                "data": ["workspaceId": "ws-1", "agentId": "agent-1",
                         "hookId": "hook-1", "name": "ci-watch", "state": "running"]
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

        // Suspend the next hook.list so a fold can land while it is in
        // flight; the suspended response still lists hook-1.
        fake.delayMap["hook.list"] = 100_000_000
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

        // Fresh server state (post-cancel) for the queued follow-up fetch.
        fake.responseMap["hook.list"] = ["hooks": [] as [[String: Any]]]
        await refetchTask.value

        // The stale response must not restore the cancelled hook; the
        // discarded response queues one follow-up fetch to converge.
        #expect(store.hooks.isEmpty)
        #expect(fake.paramsForMethod("hook.list").count == 2)
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
}
