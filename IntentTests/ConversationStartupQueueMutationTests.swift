import Foundation
@testable import Intent
import Testing

@MainActor
struct ConversationStartupQueueMutationTests {
    nonisolated private static let actions = ["append", "edit", "remove", "send-now", "send-queued"]

    @Test(arguments: Self.actions, [false, true])
    func olderBufferedQueuePreservesOnlySuccessfulLocalActions(action: String, fails: Bool) async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        configure(fixture, action: action, fails: fails)
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await waitForSeed(fixture, model)
        queueEvent(fixture, rows: [row("existing"), row("unrelated", content: "remote")])
        await perform(action, model.store, fails: fails)
        assertQueue(model.store, action: action, fails: fails, includesRemote: false)
        fixture.connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        await load.value
        assertQueue(model.store, action: action, fails: fails, includesRemote: true)
        assertTraffic(fixture.connection, action: action, queueReads: 1)
        print("Local queue action=\(action) fails=\(fails), all startup plus action: \(fixture.connection.traffic().summary)")
        queueEvent(fixture, rows: [row("later-event")])
        #expect(model.store.queuedMessages.map(\.id) == ["later-event"], "later notifications supersede the local confirmation")
        fixture.connection.responseMap["agent.getQueue"] = ["queue": [row("later-read")]]
        await model.store.fetchQueue(agentId: ConversationStartupFixture.parentId)
        #expect(model.store.queuedMessages.map(\.id) == ["later-read"])
        assertTraffic(fixture.connection, action: action, queueReads: 2)
    }

    @Test(arguments: Self.actions)
    func laterFullQueueReadSupersedesLocalActionsBeforeMetadataResolves(action: String) async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        configure(fixture, action: action)
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await waitForSeed(fixture, model)
        queueEvent(fixture, rows: [row("existing"), row("unrelated")])
        await perform(action, model.store)
        fixture.connection.responseMap["agent.getQueue"] = ["queue": [row("later-read")]]
        await model.store.fetchQueue(agentId: ConversationStartupFixture.parentId)
        fixture.connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        await load.value
        #expect(model.store.queuedMessages.map(\.id) == ["later-read"])
        assertTraffic(fixture.connection, action: action, queueReads: 2)
    }

    @Test func bufferedSnapshotsBetweenLocalActionsRetainTheirOwnChronology() async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        configure(fixture, action: "append")
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await waitForSeed(fixture, model)
        queueEvent(fixture, rows: [row("existing"), row("unrelated")])
        await perform("append", model.store)
        queueEvent(fixture, rows: [row("existing", content: "remote edit"), row("unrelated"), row("new", content: "remote append")])
        fixture.connection.responseMap["agent.editQueuedMessage"] = [:]
        try await model.store.editQueuedMessage(agentId: ConversationStartupFixture.parentId, messageId: "new", content: "local edit")
        fixture.connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        await load.value
        #expect(model.store.queuedMessages.map(\.id) == ["existing", "unrelated", "new"])
        #expect(model.store.queuedMessages.map(\.content) == ["remote edit", "before", "local edit"])
        #expect(fixture.connection.traffic().requests.count == 10)
        #expect(fixture.connection.paramsForMethod("agent.getQueue").count == 1)
    }

    @Test(arguments: Self.actions, [false, true])
    func aReadStartedBeforeTheLocalActionFoldsItsResultWithoutDroppingOtherRows(action: String, detailFirst: Bool) async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        configure(fixture, action: action)
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await waitForSeed(fixture, model)
        queueEvent(fixture, rows: [row("existing"), row("unrelated")])
        fixture.connection.pendingMethods.insert("agent.getQueue")
        let refresh = Task { await model.store.fetchQueue(agentId: ConversationStartupFixture.parentId) }
        defer { refresh.cancel() }
        try await fixture.connection.waitForPendingRequests("agent.getQueue")
        await perform(action, model.store)
        if detailFirst {
            fixture.connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
            try await waitUntil("metadata folds before the independent queue reply") { model.store.workspaceId != nil }
        }
        fixture.connection.resolvePending("agent.getQueue", with: ["queue": [row("existing"), row("unrelated", content: "new seed")]])
        await refresh.value
        if !detailFirst { fixture.connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)]) }
        await load.value
        assertQueue(model.store, action: action, fails: false, includesRemote: true)
        #expect(model.store.queuedMessages.first { $0.id == "unrelated" }?.content == "new seed")
        assertTraffic(fixture.connection, action: action, queueReads: 2)
    }

    @Test func aLaterProcessingEventStillRemovesALocallyAcknowledgedAppendDuringARead() async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        configure(fixture, action: "append")
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await waitForSeed(fixture, model)
        queueEvent(fixture, rows: [row("existing"), row("unrelated")])
        fixture.connection.pendingMethods.insert("agent.getQueue")
        let refresh = Task { await model.store.fetchQueue(agentId: ConversationStartupFixture.parentId) }
        defer { refresh.cancel() }
        try await fixture.connection.waitForPendingRequests("agent.getQueue")
        await perform("append", model.store)
        fixture.connection.deliverEvent(method: "event", params: [
            "type": "agent:queue:processing", "workspaceId": ConversationStartupFixture.workspaceId,
            "data": ["agentId": ConversationStartupFixture.parentId, "messageId": "new"]
        ])
        fixture.connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        try await waitUntil("processing event applied") { model.store.workspaceId != nil && !model.store.queuedMessages.contains { $0.id == "new" } }
        fixture.connection.resolvePending("agent.getQueue", with: ["queue": [row("existing"), row("new"), row("from-seed")]])
        await refresh.value
        await load.value
        #expect(model.store.queuedMessages.map(\.id) == ["existing", "from-seed"])
        assertTraffic(fixture.connection, action: "append", queueReads: 2)
    }

    @Test(arguments: [false, true])
    func oneWindowClosingKeepsTheOtherWindowsAcknowledgedQueueChange(acknowledgeAfterClose: Bool) async throws {
        let fixture = ConversationStartupFixture()
        let first = fixture.makeViewModel()
        let second = fixture.makeViewModel()
        configure(fixture, action: "append")
        let firstLoad = Task { await first.load() }
        let secondLoad = Task { await second.load() }
        defer { firstLoad.cancel(); secondLoad.cancel(); fixture.stop() }
        try await waitForSeed(fixture, first)
        try await waitUntil("both windows own the same conversation") { second.store.consumers.count == 2 }
        queueEvent(fixture, rows: [row("existing"), row("unrelated")])
        if acknowledgeAfterClose { fixture.connection.pendingMethods.insert("agent.queueMessage") }
        let action = Task { await perform("append", first.store) }
        defer { action.cancel() }
        if acknowledgeAfterClose { try await fixture.connection.waitForPendingRequests("agent.queueMessage") } else { await action.value }
        let registration = try #require(second.store.liveTranscript.chatSubscriptionId)
        firstLoad.cancel()
        first.teardownLiveStores()
        #expect(fixture.connection.hasSubscriptionHandler(id: registration))
        if acknowledgeAfterClose {
            fixture.connection.resolvePending("agent.queueMessage", with: reply("append"))
            action.cancel() // The ACK already succeeded; the other owner still needs it.
        }
        await action.value
        fixture.connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        await firstLoad.value
        await secondLoad.value
        assertQueue(second.store, action: "append", fails: false, includesRemote: true)
        second.teardownLiveStores()
        try await waitUntil("last window releases its channel once") { fixture.connection.traffic().calls("chat.unsubscribe").first?.completed != nil }
        #expect(fixture.connection.paramsForMethod("chat.unsubscribe").compactMap { $0["subscriptionId"] as? String } == [registration])
        #expect(!fixture.connection.hasSubscriptionHandler(id: registration))
        try await assertReleasedTraffic(fixture.connection, action: "append", openings: 1)
    }

    @Test(arguments: [false, true], Self.actions)
    func lateLocalAcknowledgementCannotChangeTheNextActivation(reset: Bool, action: String) async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        configure(fixture, action: action)
        let method = method(action)
        fixture.connection.pendingMethods.insert(method)
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await waitForSeed(fixture, model)
        queueEvent(fixture, rows: [row("existing"), row("unrelated")])
        let actionTask = Task { await perform(action, model.store, allowsCancellation: true) }
        defer { actionTask.cancel() }
        try await fixture.connection.waitForPendingRequests(method)
        let oldRegistration = try #require(model.store.liveTranscript.chatSubscriptionId)
        model.teardownLiveStores()
        if reset { model.store.reset() }
        fixture.connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        await load.value
        fixture.connection.pendingMethods = [method]
        fixture.connection.responseMap["agent.getQueue"] = ["queue": [row("existing", content: "next activation")]]
        await model.load()
        let nextRegistration = try #require(model.store.liveTranscript.chatSubscriptionId)
        #expect(oldRegistration != nextRegistration)
        fixture.connection.resolvePending(method, with: reply(action))
        await actionTask.value
        #expect(model.store.queuedMessages.map(\.id) == ["existing"])
        #expect(model.store.queuedMessages.first?.content == "next activation")
        model.teardownLiveStores()
        try await waitUntil("both activation channels released") {
            let calls = fixture.connection.traffic().calls("chat.unsubscribe")
            return calls.count == 2 && calls.allSatisfy { $0.completed != nil }
        }
        #expect(Set(fixture.connection.paramsForMethod("chat.unsubscribe").compactMap { $0["subscriptionId"] as? String }) == [oldRegistration, nextRegistration])
        #expect(!fixture.connection.hasSubscriptionHandler(id: oldRegistration))
        #expect(!fixture.connection.hasSubscriptionHandler(id: nextRegistration))
        try await assertReleasedTraffic(fixture.connection, action: action, openings: 2)
    }

    @Test func stillQueuedSendNowDoesNotInventARemoval() async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        configure(fixture, action: "send-now")
        fixture.connection.responseMap["agent.sendQueuedMessageNow"] = ["queued": true]
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await waitForSeed(fixture, model)
        queueEvent(fixture, rows: [row("existing"), row("unrelated")])
        await perform("send-now", model.store)
        fixture.connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        await load.value
        #expect(model.store.queuedMessages.map(\.id) == ["existing", "unrelated"])
        assertTraffic(fixture.connection, action: "send-now", queueReads: 1)
    }

    @Test func aPriorActivationsSendNowErrorCannotRefreshTheNewQueue() async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        configure(fixture, action: "send-now")
        fixture.connection.pendingMethods.insert("agent.sendQueuedMessageNow")
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await waitForSeed(fixture, model)
        let send = Task { await perform("send-now", model.store, fails: true) }
        defer { send.cancel() }
        try await fixture.connection.waitForPendingRequests("agent.sendQueuedMessageNow")
        model.teardownLiveStores()
        fixture.connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        await load.value
        fixture.connection.pendingMethods = ["agent.sendQueuedMessageNow"]
        await model.load()
        fixture.connection.failPending("agent.sendQueuedMessageNow", with: NSError(
            domain: "WebSocket", code: -32_602, userInfo: [NSError.intentErrorDataCodeKey: "not-found"]
        ))
        await send.value
        #expect(fixture.connection.paramsForMethod("agent.getQueue").count == 2)
        #expect(model.store.queuedMessages.map(\.id) == ["existing"])
    }
}

extension ConversationStartupQueueMutationTests {
    private func configure(_ fixture: ConversationStartupFixture, action: String, fails: Bool = false) {
        fixture.connection.pendingMethods = ["agent.get"]
        fixture.connection.responseMap["agent.getQueue"] = ["queue": [row("existing")]]
        fixture.connection.responseMap[method(action)] = reply(action)
        if fails { fixture.connection.errorMap[method(action)] = NSError(domain: "Network", code: 1) }
    }

    private func waitForSeed(_ fixture: ConversationStartupFixture, _ model: ConversationViewModel) async throws {
        try await fixture.connection.waitForPendingRequests("agent.get")
        try await waitUntil("queue seed applied while metadata is held") {
            model.store.queueReadTask == nil && model.store.queuedMessages.map(\.id) == ["existing"]
                && fixture.connection.traffic().calls("agent.getQueue").first?.completed != nil
                && fixture.connection.traffic().calls("hook.list").first?.completed != nil
                && fixture.connection.traffic().calls("prMonitor.list").first?.completed != nil
        }
        #expect(model.store.workspaceId == nil)
    }

    private func perform(
        _ action: String,
        _ store: ConversationStore,
        fails: Bool = false,
        allowsCancellation: Bool = false
    ) async {
        do {
            switch action {
            case "append": try await store.queueMessage(agentId: ConversationStartupFixture.parentId, content: "local")
            case "edit": try await store.editQueuedMessage(agentId: ConversationStartupFixture.parentId, messageId: "existing", content: "local")
            case "remove": try await store.removeQueuedMessage(agentId: ConversationStartupFixture.parentId, messageId: "existing")
            case "send-now":
                try await store.sendQueuedMessageNow(agentId: ConversationStartupFixture.parentId, messageId: "existing", workspaceId: ConversationStartupFixture.workspaceId)
            default:
                try await store.sendMessage(agentId: ConversationStartupFixture.parentId, content: "local", workspaceId: ConversationStartupFixture.workspaceId)
            }
            #expect(!fails)
        } catch is CancellationError { #expect(allowsCancellation) } catch { #expect(fails) }
    }

    private func assertQueue(_ store: ConversationStore, action: String, fails: Bool, includesRemote: Bool) {
        var ids = ["existing"]
        if includesRemote { ids.append("unrelated") }
        if !fails {
            if action == "append" || action == "send-queued" { ids.append("new") }
            if action == "remove" || action == "send-now" { ids.removeAll { $0 == "existing" } }
        }
        #expect(store.queuedMessages.map(\.id) == ids)
        if action == "edit", !fails { #expect(store.queuedMessages.first?.content == "local") }
    }

    private func method(_ action: String) -> String {
        switch action {
        case "append": "agent.queueMessage"
        case "edit": "agent.editQueuedMessage"
        case "remove": "agent.removeQueuedMessage"
        case "send-now": "agent.sendQueuedMessageNow"
        default: "agent.sendMessage"
        }
    }

    private func reply(_ action: String) -> [String: Any] {
        switch action {
        case "append": ["queuedMessage": row("new", content: "local")]
        case "send-queued": ["success": true, "queued": true, "queuedMessage": row("new", content: "local")]
        default: [:]
        }
    }

    private func row(_ id: String, content: String = "before") -> [String: Any] {
        ["id": id, "content": content, "queuedAt": "2026-09-27", "position": 0]
    }

    private func queueEvent(_ fixture: ConversationStartupFixture, rows: [[String: Any]]) {
        fixture.connection.deliverEvent(method: "event", params: [
            "type": "agent:queue:updated", "workspaceId": ConversationStartupFixture.workspaceId,
            "data": ["agentId": ConversationStartupFixture.parentId, "queue": rows]
        ])
    }

    private func assertTraffic(_ connection: RPCRecordingConnection, action: String, queueReads: Int) {
        #expect(connection.traffic().methodCounts == [
            "chat.subscribe": 1, "agent.get": 1, "agent.getQueue": queueReads, "agent.getSubscriptions": 1,
            "events.subscribe": 2, "hook.list": 1, "prMonitor.list": 1, method(action): 1
        ])
        #expect(connection.traffic().pendingCount == 0)
    }

    private func assertReleasedTraffic(_ connection: RPCRecordingConnection, action: String, openings: Int) async throws {
        let statusRegistrationCount = 2 * openings
        try await waitUntil("both window status registrations finish cleanup") {
            let calls = connection.traffic().calls("events.unsubscribe")
            return calls.count == statusRegistrationCount && calls.allSatisfy { $0.completed != nil }
        }
        #expect(connection.traffic().methodCounts == [
            "chat.subscribe": openings, "agent.get": openings, "agent.getQueue": openings,
            "agent.getSubscriptions": openings, "events.subscribe": statusRegistrationCount, "hook.list": openings, "prMonitor.list": openings,
            method(action): 1, "chat.unsubscribe": openings, "events.unsubscribe": statusRegistrationCount
        ])
        #expect(connection.traffic().pendingCount == 0)
        print("Queue ownership action=\(action) openings=\(openings), including all cleanup: \(connection.traffic().summary)")
    }
}
