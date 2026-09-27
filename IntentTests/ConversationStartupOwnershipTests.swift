import Foundation
@testable import Intent
import Testing

@MainActor
struct ConversationStartupOwnershipTests {
    @Test func sharedTranscriptKeepsEntryDividerAndSeenFocusLocalToEachWindow() async {
        let fixture = ConversationStartupFixture()
        let first = fixture.makeViewModel()
        let second = fixture.makeViewModel()
        defer { fixture.stop() }
        await first.load()
        first.store.messages.append(ConversationMessage(
            id: "later-message", role: .assistant, contentBlocks: [ContentBlock(type: .text, text: "Later")]
        ))
        await second.load()
        #expect(first.newMessagesDividerAnchorId == nil)
        #expect(second.newMessagesDividerAnchorId == ConversationStartupFixture.messageId)
        first.conversationAppeared()
        second.conversationAppeared()
        first.isAppActive = false
        second.markSeenDebounceDuration = .seconds(3600)
        second.store.isStreaming = true
        second.store.isStreaming = false
        #expect(first.markSeenDebounceTask == nil)
        #expect(second.markSeenDebounceTask != nil)
        second.markSeenDebounceTask?.cancel()
        second.markSeenDebounceTask = nil
        first.teardownLiveStores()
        second.store.isStreaming = true
        second.store.isStreaming = false
        #expect(second.markSeenDebounceTask != nil)
        #expect(second.newMessagesDividerAnchorId == ConversationStartupFixture.messageId)
        second.markSeenDebounceTask?.cancel()
    }

    @Test func twoWindowsShareChatAndKeepIndependentObserversAndDividers() async throws {
        let fixture = ConversationStartupFixture()
        let first = fixture.makeViewModel()
        let second = fixture.makeViewModel()
        let connection = fixture.connection
        let sessionHandlers = connection.eventHandlerIDs
        defer { fixture.stop() }
        await first.load()
        let firstRegistrations = try acknowledgedEventIDs(connection)
        await second.load()
        let allRegistrations = try acknowledgedEventIDs(connection)
        #expect(first.store === second.store)
        #expect(first.store.commands.agentDetails === fixture.session.agentDetails)
        #expect(connection.paramsForMethod("chat.subscribe").count == 1)
        #expect(connection.paramsForMethod("agent.getQueue").count == 1)
        #expect(connection.paramsForMethod("agent.get").count == 1)
        let handler = try #require(first.store.eventHandlerId)
        let firstObserver = try #require(first.streamingObserverId)
        let secondObserver = try #require(second.streamingObserverId)
        #expect(firstObserver != secondObserver)
        #expect(first.store.streamingObservers[secondObserver] != nil)
        first.messageText = "First draft"
        second.messageText = "Second draft"
        first.store.isStreaming = true
        #expect(first.previousIsStreaming && second.previousIsStreaming)
        first.teardownLiveStores()
        #expect(second.store.streamingObservers[firstObserver] == nil)
        #expect(second.store.streamingObservers[secondObserver] != nil)
        #expect(connection.eventHandlerIDs.contains(handler))
        #expect(connection.subscriptionHandlerCount == 1)
        #expect(!connection.didCallMethod("chat.unsubscribe"))
        try await waitUntil("only the first window's status registrations released") {
            Set(connection.paramsForMethod("events.unsubscribe").compactMap { $0["subscriptionId"] as? String }) == firstRegistrations
        }
        second.store.isStreaming = false
        #expect(!second.previousIsStreaming)
        #expect(second.messageText == "Second draft")
        #expect(first.messageText == "First draft")
        second.teardownLiveStores()
        let oldChat = try await waitForFinalRelease(connection, sessionHandlers: sessionHandlers, eventIDs: allRegistrations)
        await first.load()
        let newChat = try #require(first.store.liveTranscript.chatSubscriptionId)
        #expect(oldChat != newChat)
        #expect(!connection.hasSubscriptionHandler(id: oldChat))
        #expect(connection.hasSubscriptionHandler(id: newChat))
        #expect(connection.paramsForMethod("chat.subscribe").count == 2)
        #expect(connection.paramsForMethod("agent.get").count == 2)
    }

    @Test func reconnectReconcilesOnceForTwoWindowsOverOneActiveConversation() async throws {
        let fixture = ConversationStartupFixture()
        let first = fixture.makeViewModel()
        let second = fixture.makeViewModel()
        defer { fixture.stop() }
        await first.load()
        await second.load()
        fixture.connection.releaseConnectionStateDelivery()
        let checkpoint = fixture.connection.checkpoint
        let oldRegistration = first.store.liveTranscript.chatSubscriptionId
        fixture.connection.simulateDisconnect()
        fixture.connection.simulateConnect()
        fixture.connection.simulateConnect()
        try await waitUntil("shared reconnect metadata and snapshot") {
            let traffic = fixture.connection.traffic(since: checkpoint)
            return traffic.calls("agent.get").count == 1
                && traffic.calls("agent.getSubscriptions").count == 1
                && traffic.pendingCount == 0
                && first.store.liveTranscript.chatSeeded
                && first.store.liveTranscript.chatSubscriptionId != oldRegistration
        }
        let traffic = fixture.connection.traffic(since: checkpoint)
        #expect(traffic.calls("chat.subscribe").count == 1)
        #expect(traffic.calls("agent.getQueue").count == 1)
        #expect(traffic.calls("chat.unsubscribe").isEmpty, "dead-connection registrations are already gone")
        #expect(fixture.connection.subscriptionHandlerCount == 1)
        first.store.isStreaming = true
        #expect(first.previousIsStreaming && second.previousIsStreaming)
        first.conversationDisappeared()
        second.store.isStreaming = false
        #expect(!second.previousIsStreaming)
        #expect(second.store.streamingEventsActive)
    }

    @Test func backendSwitchKeepsEachSessionsOwnersLocal() async throws {
        let firstBackend = ConversationStartupFixture()
        let secondBackend = ConversationStartupFixture()
        let first = firstBackend.makeViewModel()
        let second = secondBackend.makeViewModel()
        defer { firstBackend.stop(); secondBackend.stop() }
        await first.load()
        await second.load()
        #expect(first.store !== second.store)
        #expect(first.agentDetails !== second.agentDetails)
        first.teardownLiveStores()
        try await waitUntil("first backend chat cleanup completed") {
            firstBackend.connection.traffic().calls("chat.unsubscribe").first?.completed != nil
        }
        #expect(secondBackend.connection.subscriptionHandlerCount == 1)
        #expect(!secondBackend.connection.didCallMethod("chat.unsubscribe"))
        secondBackend.connection.deliverEvent(method: "event", params: [
            "type": "agent:updated", "data": ["agentId": ConversationStartupFixture.parentId, "lastSeenMessageId": "other-backend"]
        ])
        #expect(second.store.lastSeenMessageId == "other-backend")
        #expect(first.store.lastSeenMessageId == ConversationStartupFixture.messageId)
    }

    @Test func cancellingBeforeLoadStartsDoesNotRegisterAnything() async {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        let load = Task { await model.load() }
        load.cancel()
        await load.value
        #expect(fixture.connection.traffic().requests.isEmpty)
        #expect(model.store.eventHandlerId == nil)
        #expect(model.detailConsumer == nil)
    }

    @Test func closingWhileSnapshotIsOwedReleasesExactlyOnceAndReappearanceUsesFreshID() async throws {
        let fixture = ConversationStartupFixture()
        let connection = fixture.connection
        let model = fixture.makeViewModel()
        connection.pendingMethods = ["chat.subscribe"]
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("chat.subscribe")
        connection.resolvePending("chat.subscribe", with: ["subscriptionId": "no-snapshot"])
        try await waitUntil("acknowledged channel without snapshot") { connection.hasSubscriptionHandler(id: "no-snapshot") }
        #expect(!model.hasLatchedNewMessagesDividerAnchor)
        model.teardownLiveStores()
        await load.value
        try await waitUntil("remote chat release completed") {
            connection.traffic().calls("chat.unsubscribe").first?.completed != nil
        }
        #expect(connection.paramsForMethod("chat.unsubscribe").count == 1)
        #expect(connection.subscriptionHandlerCount == 0)
        connection.pendingMethods = []
        await model.load()
        #expect(model.store.liveTranscript.chatSubscriptionId != "no-snapshot")
        #expect(model.hasLatchedNewMessagesDividerAnchor)
        #expect(connection.paramsForMethod("chat.subscribe").count == 2)
    }

    private func acknowledgedEventIDs(_ connection: RPCRecordingConnection) throws -> Set<String> {
        try Set(connection.traffic().calls("events.subscribe").map { request in
            let response = try JSONSerialization.jsonObject(with: #require(request.responseJSON)) as? [String: Any]
            let result = try #require(response?["result"] as? [String: Any])
            return try #require(result["subscriptionId"] as? String)
        })
    }

    private func waitForFinalRelease(
        _ connection: RPCRecordingConnection, sessionHandlers: Set<UUID>, eventIDs: Set<String>
    ) async throws -> String {
        try await waitUntil("all acknowledged remote registrations released") {
            connection.traffic().calls("events.unsubscribe").count == eventIDs.count
                && connection.traffic().calls("chat.unsubscribe").count == 1
                && connection.traffic().pendingCount == 0
        }
        #expect(connection.eventHandlerIDs == sessionHandlers)
        #expect(connection.subscriptionHandlerCount == 0)
        let eventReleases = connection.paramsForMethod("events.unsubscribe").compactMap { $0["subscriptionId"] as? String }
        #expect(Set(eventReleases) == eventIDs)
        #expect(eventReleases.count == eventIDs.count, "each acknowledged registration is released exactly once")
        let released = connection.paramsForMethod("chat.unsubscribe").compactMap { $0["subscriptionId"] as? String }
        #expect(Set(released).count == released.count)
        return try #require(released.first)
    }
}
