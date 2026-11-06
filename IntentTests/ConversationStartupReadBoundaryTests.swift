import Foundation
@testable import Intent
import Testing

@MainActor
struct ConversationStartupReadBoundaryTests {
    @Test(arguments: [false, true], [false, true])
    func laterSeedsSupersedeBufferedEventsInEitherCompletionOrder(detailFirst: Bool, processing: Bool) async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        let connection = fixture.connection
        connection.pendingMethods = ["agent.get", "agent.getQueue"]
        let lease = bindBeforeRequests(model, fixture: fixture)
        defer { fixture.details.release(agentId: ConversationStartupFixture.parentId, consumer: lease) }
        event("agent:updated", fixture, ["lastSeenMessageId": "earlier-event"])
        if processing { event("agent:queue:processing", fixture, ["messageId": "later-seed"]) } else { event("agent:queue:updated", fixture, ["queue": [row("earlier-event")]]) }
        #expect(connection.traffic().requests.isEmpty)
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("agent.get")
        try await connection.waitForPendingRequests("agent.getQueue")
        fixture.parentMetadata = ["lastSeenMessageId": "later-seed"]
        if detailFirst {
            connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
            try await waitUntil("workspace authority before queue reply") { model.store.workspaceId != nil }
            connection.resolvePending("agent.getQueue", with: ["queue": [row("later-seed")]])
        } else {
            connection.resolvePending("agent.getQueue", with: ["queue": [row("later-seed")]])
            try await waitUntil("queue applied before workspace authority") { model.store.queuedMessages.map(\.id) == ["later-seed"] }
            connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        }
        await load.value
        #expect(model.store.lastSeenMessageId == "later-seed")
        #expect(fixture.details.cached(agentId: ConversationStartupFixture.parentId)?.metadata["lastSeenMessageId"] as? String == "later-seed")
        #expect(model.store.queuedMessages.map(\.id) == ["later-seed"])
        assertCoreReads(connection)
    }

    @Test(arguments: ["omitted", "nil", "malformed", "empty"], ["lastSeenMessageId", "pendingQuestionsMessageId", "dismissedQuestionsMessageId"])
    func onlyReturnedStringFieldsSupersedeEarlierMarkers(valueKind: String, field: String) async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        let connection = fixture.connection
        connection.pendingMethods = ["agent.get"]
        let lease = bindBeforeRequests(model, fixture: fixture)
        defer { fixture.details.release(agentId: ConversationStartupFixture.parentId, consumer: lease) }
        let value = ConversationStartupFixture.messageId
        event("agent:updated", fixture, [field: value])
        #expect(connection.traffic().requests.isEmpty)
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("agent.get")
        fixture.parentMetadata = ["pendingProposals": []]
        if valueKind == "nil" { fixture.parentMetadata[field] = NSNull() }
        if valueKind == "malformed" { fixture.parentMetadata[field] = 7 }
        if valueKind == "empty" { fixture.parentMetadata[field] = "" }
        connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        await load.value
        let expected = valueKind == "empty" ? "" : value
        #expect(marker(field, model.store) == expected)
        #expect(fixture.details.cached(agentId: ConversationStartupFixture.parentId)?.metadata[field] as? String == expected)
        assertCoreReads(connection)
    }

    @Test func joiningARestoredRouteReadUsesItsActualStartAndSeparateQueueBoundary() async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        let connection = fixture.connection
        connection.pendingMethods = ["agent.get"]
        let route = Task { try await fixture.details.load(agentId: ConversationStartupFixture.parentId) }
        defer { route.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("agent.get")
        let lease = bindBeforeRequests(model, fixture: fixture)
        defer { fixture.details.release(agentId: ConversationStartupFixture.parentId, consumer: lease) }
        event("agent:updated", fixture, ["lastSeenMessageId": "during-shared-read"])
        event("agent:queue:updated", fixture, ["queue": [row("before-queue-read")]])
        #expect(connection.traffic().methodCounts == ["agent.get": 1])
        connection.responseMap["agent.getQueue"] = ["queue": [row("later-queue")]]
        let load = Task { await model.load() }
        defer { load.cancel() }
        try await waitUntil("queue seed while the restored route remains pending") { model.store.queuedMessages.map(\.id) == ["later-queue"] }
        fixture.parentMetadata = ["lastSeenMessageId": "old-seed"]
        connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        _ = try await route.value
        await load.value
        #expect(model.store.lastSeenMessageId == "during-shared-read")
        #expect(fixture.details.cached(agentId: ConversationStartupFixture.parentId)?.metadata["lastSeenMessageId"] as? String == "during-shared-read")
        #expect(model.store.queuedMessages.map(\.id) == ["later-queue"])
        assertCoreReads(connection)
    }

    @Test(arguments: [false, true], [false, true])
    func queueEventsDuringTheReadWinInEitherCompletionOrder(detailFirst: Bool, processing: Bool) async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        let connection = fixture.connection
        connection.pendingMethods = ["agent.get", "agent.getQueue"]
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("agent.get")
        try await connection.waitForPendingRequests("agent.getQueue")
        if processing { event("agent:queue:processing", fixture, ["messageId": "removed"]) } else { event("agent:queue:updated", fixture, ["queue": [row("new-event")]]) }
        if detailFirst {
            connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
            try await waitUntil("workspace authority before queue reply") { model.store.workspaceId != nil }
        }
        connection.resolvePending("agent.getQueue", with: ["queue": [row("removed"), row("remaining")]])
        if !detailFirst {
            try await waitUntil("queue reply before authority") { !model.store.queueReads.isRunning }
            connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        }
        await load.value
        #expect(model.store.queuedMessages.map(\.id) == (processing ? ["remaining"] : ["new-event"]))
        assertCoreReads(connection)
    }

    @Test(arguments: ["failure", "malformed", "partial"], [false, true])
    func anUnsuccessfulQueueSeedDoesNotSupersedeBufferedRows(result: String, detailFirst: Bool) async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        let connection = fixture.connection
        connection.pendingMethods = ["agent.get", "agent.getQueue"]
        let lease = bindBeforeRequests(model, fixture: fixture)
        defer { fixture.details.release(agentId: ConversationStartupFixture.parentId, consumer: lease) }
        event("agent:queue:updated", fixture, ["queue": [row("preserved")]])
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("agent.get")
        try await connection.waitForPendingRequests("agent.getQueue")
        if detailFirst {
            connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
            try await waitUntil("authority applied the buffered queue") { model.store.queuedMessages.map(\.id) == ["preserved"] }
        }
        if result == "failure" {
            connection.failPending("agent.getQueue", with: NSError(domain: "Network", code: 1))
        } else if result == "partial" {
            connection.resolvePending("agent.getQueue", with: ["queue": [row("partial"), ["id": "invalid"]]])
        } else {
            connection.resolvePending("agent.getQueue", with: ["queue": NSNull()])
        }
        try await waitUntil("unsuccessful queue settled") { !model.store.queueReads.isRunning }
        if !detailFirst { connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)]) }
        await load.value
        #expect(model.store.queuedMessages.map(\.id) == ["preserved"])
        assertCoreReads(connection)
    }

    @Test(arguments: ["failure", "malformed", "missing-workspace"])
    func failedDetailDoesNotGiveOmittedRecoveryFieldsAuthority(result: String) async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        let connection = fixture.connection
        connection.pendingMethods = ["agent.get"]
        let lease = bindBeforeRequests(model, fixture: fixture)
        defer { fixture.details.release(agentId: ConversationStartupFixture.parentId, consumer: lease) }
        event("agent:updated", fixture, ["lastSeenMessageId": "preserved", "dismissedQuestionsMessageId": "dismissed"])
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("agent.get")
        if result == "malformed" { connection.resolvePending("agent.get", with: ["agent": [:]]) } else if result == "missing-workspace" {
            var agent = fixture.agent(ConversationStartupFixture.parentId)
            agent["workspaceId"] = nil
            connection.resolvePending("agent.get", with: ["agent": agent])
        } else { connection.failPending("agent.get", with: NSError(domain: "Network", code: 1)) }
        await load.value
        #expect(!model.isEntryScrollReady)
        fixture.parentMetadata = ["lastSeenMessageId": NSNull(), "pendingQuestionsMessageId": ""]
        event("agent:updated", fixture, ["pendingQuestionsMessageId": ""])
        try await connection.waitForPendingRequests("agent.get")
        connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        try await waitUntil("recovered metadata") { model.isEntryScrollReady }
        #expect(model.store.lastSeenMessageId == "preserved")
        #expect(model.store.dismissedQuestionsMessageId == "dismissed")
        #expect(model.store.pendingQuestionsMessageId?.isEmpty == true)
        #expect(fixture.details.cached(agentId: ConversationStartupFixture.parentId)?.metadata["lastSeenMessageId"] as? String == "preserved")
        #expect(connection.paramsForMethod("agent.get").count == 2)
        #expect(connection.paramsForMethod("agent.getQueue").count == 1)
    }

    @Test func aSuccessfulTrailingDetailReadSupersedesOnlyItsReturnedFields() async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        let connection = fixture.connection
        connection.pendingMethods = ["agent.get"]
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("agent.get")
        event("agent:updated", fixture, ["lastSeenMessageId": "before-trailing", "dismissedQuestionsMessageId": "preserved"])
        fixture.details.invalidate(agentId: ConversationStartupFixture.parentId)
        connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        try await connection.waitForPendingRequests("agent.get")
        fixture.parentMetadata = ["lastSeenMessageId": "trailing-seed"]
        connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        await load.value
        #expect(model.store.lastSeenMessageId == "trailing-seed")
        #expect(model.store.dismissedQuestionsMessageId == "preserved")
        #expect(fixture.details.cached(agentId: ConversationStartupFixture.parentId)?.metadata["dismissedQuestionsMessageId"] as? String == "preserved")
        #expect(connection.paramsForMethod("agent.get").count == 2)
        #expect(connection.paramsForMethod("agent.getQueue").count == 1)
    }

    private func bindBeforeRequests(_ model: ConversationViewModel, fixture: ConversationStartupFixture) -> UUID {
        let lease = fixture.details.retain(agentId: ConversationStartupFixture.parentId)
        model.store.retainConversation(
            model.conversationConsumer, agentId: ConversationStartupFixture.parentId, workspaceId: ConversationStartupFixture.workspaceId
        )
        return lease
    }

    private func event(_ type: String, _ fixture: ConversationStartupFixture, _ fields: [String: Any]) {
        fixture.connection.deliverEvent(method: "event", params: [
            "type": type, "workspaceId": ConversationStartupFixture.workspaceId,
            "data": fields.merging(["agentId": ConversationStartupFixture.parentId]) { _, value in value }
        ])
    }

    private func row(_ id: String) -> [String: Any] {
        ["id": id, "content": id, "queuedAt": "2026-09-27", "position": 0]
    }

    private func marker(_ field: String, _ store: ConversationStore) -> String? {
        switch field {
        case "pendingQuestionsMessageId": store.pendingQuestionsMessageId
        case "dismissedQuestionsMessageId": store.dismissedQuestionsMessageId
        default: store.lastSeenMessageId
        }
    }

    private func assertCoreReads(_ connection: RPCRecordingConnection) {
        for method in ["agent.get", "agent.getQueue", "agent.getSubscriptions", "chat.subscribe"] {
            #expect(connection.paramsForMethod(method).count == 1)
        }
        #expect(connection.traffic().methodCounts == [
            "chat.subscribe": 1, "agent.get": 1, "agent.getQueue": 1, "agent.getSubscriptions": 1,
            "events.subscribe": 2, "hook.list": 1, "prMonitor.list": 1
        ])
        #expect(!connection.didCallMethod("agent.getConversation"))
    }
}
