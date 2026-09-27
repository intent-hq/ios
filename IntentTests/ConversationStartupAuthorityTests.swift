import Foundation
@testable import Intent
import Testing

@MainActor
struct ConversationStartupAuthorityTests {
    @Test(arguments: [false, true])
    func mixedScopeEventsFoldInArrivalOrderWithoutAnEarlyEntryLatch(scopedFirst: Bool) async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        let connection = fixture.connection
        connection.pendingMethods = ["agent.get"]
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("agent.get")
        try await waitUntil("snapshot and queue before metadata") {
            model.store.liveTranscript.chatSeeded && model.store.queueReadTask == nil
        }
        for (scoped, value) in [(scopedFirst, "older"), (!scopedFirst, "newer")] {
            event("agent:updated", fixture: fixture, scoped: scoped, fields: ["lastSeenMessageId": value])
            event("agent:queue:updated", fixture: fixture, scoped: scoped, fields: ["queue": [row(value)]])
        }
        event("agent:updated", fixture: fixture, scoped: true, fields: ["pendingQuestionsMessageId": ""])
        event("agent:updated", fixture: fixture, scoped: false, fields: ["dismissedQuestionsMessageId": "dismissed"])
        #expect(!model.isEntryScrollReady)
        #expect(model.newMessagesDividerAnchorId == nil)
        connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        await load.value
        #expect(model.isEntryScrollReady)
        #expect(model.store.lastSeenMessageId == "newer")
        #expect(model.store.pendingQuestionsMessageId?.isEmpty == true)
        #expect(model.store.dismissedQuestionsMessageId == "dismissed")
        #expect(model.store.queuedMessages.map(\.id) == ["newer"])
        #expect(fixture.details.cached(agentId: ConversationStartupFixture.parentId)?.metadata["lastSeenMessageId"] as? String == "newer")
        #expect(connection.paramsForMethod("agent.get").count == 1)
        #expect(connection.paramsForMethod("agent.getQueue").count == 1)
    }

    @Test(arguments: ["lastSeenMessageId", "dismissedQuestionsMessageId"], [false, true])
    func successfulLocalMarkersSurviveOlderBufferedEventsButFailedActionsDoNotHideThem(field: String, succeeds: Bool) async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        let connection = fixture.connection
        connection.pendingMethods = ["agent.get"]
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("agent.get")
        try await waitUntil("snapshot before local marker command") { model.store.liveTranscript.chatSeeded }
        event("agent:updated", fixture: fixture, scoped: true, fields: [field: "older", "pendingQuestionsMessageId": ""])
        let method = field == "lastSeenMessageId" ? "agent.markSeen" : "agent.dismissQuestions"
        connection.responseMap[method] = [field: ConversationStartupFixture.messageId]
        if !succeeds { connection.errorMap[method] = NSError(domain: "Network", code: 1) }
        if field == "lastSeenMessageId" {
            await model.store.markSeen(agentId: ConversationStartupFixture.parentId, workspaceId: ConversationStartupFixture.workspaceId)
        } else {
            do {
                try await model.store.dismissQuestions(
                    agentId: ConversationStartupFixture.parentId,
                    messageId: ConversationStartupFixture.messageId,
                    workspaceId: ConversationStartupFixture.workspaceId
                )
                #expect(succeeds)
            } catch { #expect(!succeeds) }
        }
        connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        await load.value
        let expected = succeeds ? ConversationStartupFixture.messageId : "older"
        #expect(marker(field, in: model.store) == expected)
        #expect(model.store.pendingQuestionsMessageId?.isEmpty == true, "a local change preserves unrelated event fields")
        #expect(fixture.details.cached(agentId: ConversationStartupFixture.parentId)?.metadata[field] as? String == expected)
        event("agent:updated", fixture: fixture, scoped: false, fields: [field: "latest"])
        #expect(marker(field, in: model.store) == "latest", "later unscoped events remain valid")
    }

    @Test(arguments: [false, true], [false, true])
    func subscriptionSeedWaitsForCanonicalScopeInEitherCompletionOrder(seedFirst: Bool, staleHint: Bool) async throws {
        let fixture = ConversationStartupFixture()
        let connection = fixture.connection
        connection.pendingMethods = ["agent.get", "agent.getSubscriptions"]
        fixture.watchedIds = [ConversationStartupFixture.childId]
        let first = fixture.makeViewModel(workspaceId: staleHint ? "stale-workspace" : ConversationStartupFixture.workspaceId)
        let firstLoad = Task { await first.load() }
        defer { firstLoad.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("agent.getSubscriptions")
        let valid = fixture.makeViewModel()
        let validLoad = Task { await valid.load() }
        defer { validLoad.cancel() }
        try await waitUntil("second window shares the owner") { valid.store.consumers.contains(valid.conversationConsumer) }
        try await waitUntil("both workspace status seeds complete before authority changes") {
            let traffic = connection.traffic()
            let count = staleHint ? 2 : 1
            return traffic.calls("hook.list").filter { $0.completed != nil }.count == count
                && traffic.calls("prMonitor.list").filter { $0.completed != nil }.count == count
        }
        if seedFirst {
            connection.resolvePending("agent.getSubscriptions", with: fixture.subscriptions())
            try await expectNever("subscription effects before workspace authority") {
                connection.didCallMethod("agent.list") || !valid.store.watchedAgentIds.isEmpty
            }
        }
        connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        try await waitUntil("canonical workspace applied") { valid.store.workspaceId == ConversationStartupFixture.workspaceId }
        if !seedFirst { connection.resolvePending("agent.getSubscriptions", with: fixture.subscriptions()) }
        if staleHint {
            try await connection.waitForPendingRequests("agent.getSubscriptions")
            #expect(connection.paramsForMethod("agent.getSubscriptions").last?["workspaceId"] as? String == ConversationStartupFixture.workspaceId)
            #expect(!connection.didCallMethod("agent.list"))
            connection.resolvePending("agent.getSubscriptions", with: fixture.subscriptions())
        }
        await firstLoad.value
        await validLoad.value
        #expect(valid.store.watchedAgentIds == [ConversationStartupFixture.childId])
        #expect(connection.paramsForMethod("agent.list").compactMap { $0["workspaceId"] as? String } == [ConversationStartupFixture.workspaceId])
        #expect(connection.paramsForMethod("agent.getSubscriptions").count == (staleHint ? 2 : 1))
        for method in ["chat.subscribe", "agent.get", "agent.getQueue"] { #expect(connection.paramsForMethod(method).count == 1) }
        first.teardownLiveStores()
        let registration = try #require(valid.store.liveTranscript.chatSubscriptionId)
        #expect(connection.hasSubscriptionHandler(id: registration))
        valid.teardownLiveStores()
        try await waitUntil("final channel cleanup") { connection.traffic().calls("chat.unsubscribe").first?.completed != nil }
        #expect(connection.paramsForMethod("chat.unsubscribe").compactMap { $0["subscriptionId"] as? String } == [registration])
        try await assertSharedReleaseTraffic(connection, seedFirst: seedFirst, staleHint: staleHint)
    }

    @Test func aLaterBufferedNotificationCanSupersedeOneSuccessfulLocalMarker() async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        let connection = fixture.connection
        connection.pendingMethods = ["agent.get"]
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("agent.get")
        try await waitUntil("snapshot before marker commands") { model.store.liveTranscript.chatSeeded }
        event("agent:updated", fixture: fixture, scoped: true, fields: ["lastSeenMessageId": "old", "dismissedQuestionsMessageId": "old"])
        connection.responseMap["agent.markSeen"] = ["lastSeenMessageId": ConversationStartupFixture.messageId]
        connection.responseMap["agent.dismissQuestions"] = ["dismissedQuestionsMessageId": ConversationStartupFixture.messageId]
        await model.store.markSeen(agentId: ConversationStartupFixture.parentId, workspaceId: ConversationStartupFixture.workspaceId)
        try await model.store.dismissQuestions(
            agentId: ConversationStartupFixture.parentId,
            messageId: ConversationStartupFixture.messageId,
            workspaceId: ConversationStartupFixture.workspaceId
        )
        event("agent:updated", fixture: fixture, scoped: false, fields: ["lastSeenMessageId": "latest"])
        #expect(!model.isEntryScrollReady)
        connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        await load.value
        #expect(model.store.lastSeenMessageId == "latest")
        #expect(model.store.dismissedQuestionsMessageId == ConversationStartupFixture.messageId)
        #expect(fixture.details.cached(agentId: ConversationStartupFixture.parentId)?.metadata["lastSeenMessageId"] as? String == "latest")
    }

    @Test(arguments: [false, true])
    func failedAuthorityReleasesTheLoadAndRecoveryAppliesOnlyCanonicalSubscriptions(missingWorkspace: Bool) async throws {
        let fixture = ConversationStartupFixture()
        let connection = fixture.connection
        fixture.watchedIds = [ConversationStartupFixture.childId]
        connection.pendingMethods = ["agent.get", "agent.getSubscriptions"]
        let model = fixture.makeViewModel()
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("agent.getSubscriptions")
        connection.resolvePending("agent.getSubscriptions", with: fixture.subscriptions())
        try await expectNever("children before failed authority") { connection.didCallMethod("agent.list") }
        if missingWorkspace {
            var agent = fixture.agent(ConversationStartupFixture.parentId)
            agent["workspaceId"] = nil
            connection.resolvePending("agent.get", with: ["agent": agent])
        } else { connection.failPending("agent.get", with: NSError(domain: "Network", code: 1)) }
        await load.value
        #expect(!model.isEntryScrollReady && model.store.watchedAgentIds.isEmpty)
        event("agent:updated", fixture: fixture, scoped: false, fields: ["lastSeenMessageId": "recovered"])
        try await connection.waitForPendingRequests("agent.get")
        connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        try await connection.waitForPendingRequests("agent.getSubscriptions")
        connection.resolvePending("agent.getSubscriptions", with: fixture.subscriptions())
        try await waitUntil("recovered subscriptions") { model.isEntryScrollReady && model.store.watchedAgents.count == 1 }
        #expect(connection.paramsForMethod("agent.getSubscriptions").count == 2)
        #expect(connection.paramsForMethod("agent.get").count == 2)
        #expect(connection.paramsForMethod("agent.list").count == 1)
        #expect(connection.paramsForMethod("chat.subscribe").count == 1)
        let traffic = connection.traffic()
        #expect(traffic.methodCounts == [
            "chat.subscribe": 1, "agent.get": 2, "agent.getQueue": 1, "agent.getSubscriptions": 2,
            "agent.list": 1, "events.subscribe": 2, "hook.list": 1, "prMonitor.list": 1
        ])
        #expect(traffic.pendingCount == 0 && traffic.failures.count == (missingWorkspace ? 0 : 1))
        print("Authority failure and recovery missingWorkspace=\(missingWorkspace), all startup side calls: \(traffic.summary)")
    }

    private func marker(_ field: String, in store: ConversationStore) -> String? {
        field == "lastSeenMessageId" ? store.lastSeenMessageId : store.dismissedQuestionsMessageId
    }

    @Test func authorityWaitBelongsToTheSharedOwnerAndIsReleasedOnFinalClose() async throws {
        let fixture = ConversationStartupFixture()
        let connection = fixture.connection
        fixture.watchedIds = [ConversationStartupFixture.childId]
        connection.pendingMethods = ["agent.get"]
        let first = fixture.makeViewModel()
        let second = fixture.makeViewModel()
        let firstLoad = Task { await first.load() }
        defer { firstLoad.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("agent.get")
        let secondLoad = Task { await second.load() }
        defer { secondLoad.cancel() }
        try await waitUntil("shared authority wait") {
            second.store.consumers.count == 2 && !second.store.workspaceAuthorityWaiters.isEmpty
        }
        let registration = try #require(second.store.liveTranscript.chatSubscriptionId)
        firstLoad.cancel()
        first.teardownLiveStores()
        #expect(connection.hasSubscriptionHandler(id: registration))
        #expect(!second.store.workspaceAuthorityWaiters.isEmpty)
        second.teardownLiveStores()
        #expect(second.store.workspaceAuthorityWaiters.isEmpty)
        connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        await firstLoad.value
        await secondLoad.value
        try await expectNever("late authority applies closed-window children") { connection.didCallMethod("agent.list") }
        try await waitUntil("exact final cleanup") { connection.traffic().calls("chat.unsubscribe").first?.completed != nil }
        #expect(connection.paramsForMethod("chat.unsubscribe").compactMap { $0["subscriptionId"] as? String } == [registration])
        #expect(connection.paramsForMethod("agent.getSubscriptions").count == 1)
    }

    private func event(_ type: String, fixture: ConversationStartupFixture, scoped: Bool, fields: [String: Any]) {
        var params: [String: Any] = ["type": type, "data": fields.merging(["agentId": ConversationStartupFixture.parentId]) { _, value in value }]
        if scoped { params["workspaceId"] = ConversationStartupFixture.workspaceId }
        fixture.connection.deliverEvent(method: "event", params: params)
    }

    private func row(_ id: String) -> [String: Any] {
        ["id": id, "content": id, "queuedAt": "2026-09-27", "position": 0]
    }

    private func assertSharedReleaseTraffic(_ connection: RPCRecordingConnection, seedFirst: Bool, staleHint: Bool) async throws {
        let registrations = staleHint ? 3 : 2
        let lists = staleHint ? 2 : 1
        try await waitUntil("all window status cleanup completes") {
            let releases = connection.traffic().calls("events.unsubscribe")
            return releases.count == registrations && releases.allSatisfy { $0.completed != nil }
        }
        let traffic = connection.traffic()
        #expect(traffic.methodCounts == [
            "chat.subscribe": 1, "chat.unsubscribe": 1, "agent.get": 1, "agent.getQueue": 1,
            "agent.getSubscriptions": staleHint ? 2 : 1, "agent.list": 1,
            "events.subscribe": registrations, "events.unsubscribe": registrations, "hook.list": lists, "prMonitor.list": lists
        ])
        #expect(traffic.pendingCount == 0 && traffic.failures.isEmpty)
        print("Authority scope seedFirst=\(seedFirst) staleHint=\(staleHint), including both-window cleanup: \(traffic.summary)")
    }
}
