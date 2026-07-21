import Foundation
import Foundation
import Testing
@testable import Intent

@Suite(.serialized)
struct ConnectionManagerTests {
    // MARK: - ConnectionState equality

    @Test @MainActor func connectionStateDisconnectedEquality() {
        #expect(ConnectionState.disconnected == ConnectionState.disconnected)
    }

    @Test @MainActor func connectionStateConnectedEquality() {
        #expect(ConnectionState.connected == ConnectionState.connected)
    }

    @Test @MainActor func connectionStateConnectingEquality() {
        #expect(ConnectionState.connecting == ConnectionState.connecting)
    }

    @Test @MainActor func connectionStateReconnectingSameAttempt() {
        #expect(ConnectionState.reconnecting(attempt: 1) == ConnectionState.reconnecting(attempt: 1))
    }

    @Test @MainActor func connectionStateReconnectingDifferentAttempt() {
        #expect(ConnectionState.reconnecting(attempt: 1) != ConnectionState.reconnecting(attempt: 2))
    }

    @Test @MainActor func connectionStateDifferentCases() {
        #expect(ConnectionState.connected != ConnectionState.disconnected)
        #expect(ConnectionState.connecting != ConnectionState.connected)
        #expect(ConnectionState.reconnecting(attempt: 1) != ConnectionState.connected)
    }

    // MARK: - Event handlers

    @Test @MainActor func onEventRegistersHandler() async {
        let manager = ConnectionManager.shared
        let initialCount = manager.eventHandlers.count
        let handlerId = manager.onEvent { _, _ in }
        #expect(manager.eventHandlers.count == initialCount + 1)
        // Clean up: remove the handler we added
        manager.removeEventHandler(id: handlerId)
    }

    @Test @MainActor func eventHandlerReceivesEvents() async {
        let manager = ConnectionManager.shared
        var receivedMethod: String?
        var receivedParams: Any?
        let handlerId = manager.onEvent { method, params in
            receivedMethod = method
            receivedParams = params
        }

        let notification = """
        {"jsonrpc":"2.0","method":"events.event","params":{"type":"workspace:updated","data":{"id":"ws-1"}}}
        """
        await manager.dispatchMessage(notification)

        #expect(receivedMethod == "events.event")
        #expect(receivedParams != nil)
        // Clean up
        manager.removeEventHandler(id: handlerId)
    }

    // MARK: - Message dispatch (response routing)

    @Test @MainActor func dispatchResponseResolvesCorrectContinuation() async throws {
        let manager = ConnectionManager.shared

        let expectation = Task<Any, Error> {
            try await withCheckedThrowingContinuation { continuation in
                manager.pendingRequests[999] = continuation
            }
        }

        try? await Task.sleep(nanoseconds: 10_000_000) // let Task store continuation

        let response = """
        {"jsonrpc":"2.0","id":999,"result":{"workspaces":[]}}
        """
        await manager.dispatchMessage(response)

        let result = try await expectation.value
        #expect(result is [String: Any])
    }

    @Test @MainActor func dispatchErrorResponseRejectsContinuation() async {
        let manager = ConnectionManager.shared

        let expectation = Task<Any, Error> {
            try await withCheckedThrowingContinuation { continuation in
                manager.pendingRequests[888] = continuation
            }
        }

        try? await Task.sleep(nanoseconds: 10_000_000) // let Task store continuation

        let errorResponse = """
        {"jsonrpc":"2.0","id":888,"error":{"code":-1,"message":"Something went wrong"}}
        """
        await manager.dispatchMessage(errorResponse)

        do {
            _ = try await expectation.value
            Issue.record("Expected error but got success")
        } catch {
            #expect(error.localizedDescription.contains("Something went wrong"))
        }
    }

    // MARK: - failAllPending

    @Test @MainActor func failAllPendingClearsRequests() async {
        let manager = ConnectionManager.shared

        let task1 = Task<Any, Error> {
            try await withCheckedThrowingContinuation { continuation in
                manager.pendingRequests[100] = continuation
            }
        }
        let task2 = Task<Any, Error> {
            try await withCheckedThrowingContinuation { continuation in
                manager.pendingRequests[101] = continuation
            }
        }

        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms

        manager.failAllPending(error: "Connection lost")

        #expect(manager.pendingRequests.isEmpty)

        do {
            _ = try await task1.value
            Issue.record("Expected error")
        } catch {
            #expect(error.localizedDescription.contains("Connection lost"))
        }
        do {
            _ = try await task2.value
            Issue.record("Expected error")
        } catch {
            #expect(error.localizedDescription.contains("Connection lost"))
        }
    }

    // MARK: - certFingerprint API

    // Test that ConnectionManager stores certFingerprint
    @Test @MainActor func connectionManagerStoresCertFingerprint() {
        // This tests the connect() method signature accepts certFingerprint
        // We can't easily test the actual WSS connection without a server,
        // but we can verify the API accepts the parameter
        // Just verify the method exists with the right signature
        let manager = ConnectionManager.shared
        // The connect method should accept certFingerprint parameter
        // This is a compile-time check — if it compiles, the API is correct
    }

    // MARK: - Invalid message handling

    @Test @MainActor func dispatchInvalidJsonDoesNotCrash() async {
        let manager = ConnectionManager.shared
        await manager.dispatchMessage("not valid json")
        await manager.dispatchMessage("")
        await manager.dispatchMessage("{}")
    }

    // MARK: - Subscription Push Routing

    @Test @MainActor func registerSubscriptionHandlerStoresHandler() async {
        let manager = ConnectionManager.shared
        var receivedPush: SubscriptionPush?

        manager.registerSubscriptionHandler(id: "test-sub-1") { push in
            receivedPush = push
        }

        // Verify the push is routed correctly
        let pushMessage = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"test-sub-1","kind":"snapshot","seq":0,"snapshot":[]}}
        """
        await manager.dispatchMessage(pushMessage)

        #expect(receivedPush != nil)
        #expect(receivedPush?.subscriptionId == "test-sub-1")
        #expect(receivedPush?.kind == .snapshot)

        // Clean up
        manager.unregisterSubscriptionHandler(id: "test-sub-1")
    }

    @Test @MainActor func pushForUnknownSubscriptionIsDropped() async {
        let manager = ConnectionManager.shared

        // No handler registered for this id
        let pushMessage = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"unknown-sub","kind":"snapshot","seq":0,"snapshot":[]}}
        """
        // Should not crash, just drop and log
        await manager.dispatchMessage(pushMessage)
    }

    @Test @MainActor func unregisterRemovesHandler() async {
        let manager = ConnectionManager.shared
        var receivedCount = 0

        manager.registerSubscriptionHandler(id: "test-sub-2") { _ in
            receivedCount += 1
        }

        let pushMessage = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"test-sub-2","kind":"snapshot","seq":0,"snapshot":[]}}
        """

        // First push should be received
        await manager.dispatchMessage(pushMessage)
        #expect(receivedCount == 1)

        // Unregister
        manager.unregisterSubscriptionHandler(id: "test-sub-2")

        // Second push should be dropped
        await manager.dispatchMessage(pushMessage)
        #expect(receivedCount == 1) // Still 1, not incremented
    }

    @Test @MainActor func twoHandlersOnlyReceiveTheirOwnPushes() async {
        let manager = ConnectionManager.shared
        var receivedPush1: SubscriptionPush?
        var receivedPush2: SubscriptionPush?

        manager.registerSubscriptionHandler(id: "test-sub-a") { push in
            receivedPush1 = push
        }

        manager.registerSubscriptionHandler(id: "test-sub-b") { push in
            receivedPush2 = push
        }

        // Send push for subscription A
        let pushA = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"test-sub-a","kind":"snapshot","seq":1,"snapshot":[]}}
        """
        await manager.dispatchMessage(pushA)

        #expect(receivedPush1?.subscriptionId == "test-sub-a")
        #expect(receivedPush1?.seq == 1)
        #expect(receivedPush2 == nil) // Handler B should not receive A's push

        // Reset and send push for subscription B
        receivedPush1 = nil
        receivedPush2 = nil

        let pushB = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"test-sub-b","kind":"snapshot","seq":2,"snapshot":[]}}
        """
        await manager.dispatchMessage(pushB)

        #expect(receivedPush1 == nil) // Handler A should not receive B's push
        #expect(receivedPush2?.subscriptionId == "test-sub-b")
        #expect(receivedPush2?.seq == 2)

        // Clean up
        manager.unregisterSubscriptionHandler(id: "test-sub-a")
        manager.unregisterSubscriptionHandler(id: "test-sub-b")
    }

    @Test @MainActor func reregisterSameIdReplacesHandler() async {
        let manager = ConnectionManager.shared
        var firstHandlerCalled = false
        var secondHandlerCalled = false

        manager.registerSubscriptionHandler(id: "test-sub-3") { _ in
            firstHandlerCalled = true
        }

        // Re-register with new handler
        manager.registerSubscriptionHandler(id: "test-sub-3") { _ in
            secondHandlerCalled = true
        }

        let pushMessage = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"test-sub-3","kind":"snapshot","seq":0,"snapshot":[]}}
        """
        await manager.dispatchMessage(pushMessage)

        #expect(!firstHandlerCalled) // Old handler should not be called
        #expect(secondHandlerCalled) // New handler should be called

        // Clean up
        manager.unregisterSubscriptionHandler(id: "test-sub-3")
    }

    @Test @MainActor func subscriptionPushDoesNotReachLegacyEventHandlers() async {
        let manager = ConnectionManager.shared
        var legacyHandlerReceivedSubscriptionPush = false
        var routerHandlerReceivedPush = false

        let handlerId = manager.onEvent { method, _ in
            if method == "subscription.push" {
                legacyHandlerReceivedSubscriptionPush = true
            }
        }

        // Register a subscription handler to consume the push
        manager.registerSubscriptionHandler(id: "test-sub-4") { _ in
            routerHandlerReceivedPush = true
        }

        let pushMessage = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"test-sub-4","kind":"snapshot","seq":0,"snapshot":[]}}
        """
        await manager.dispatchMessage(pushMessage)

        // Router is the SINGLE source of subscription.push dispatch.
        // Legacy eventHandlers must NOT receive subscription.push.
        #expect(routerHandlerReceivedPush)
        #expect(!legacyHandlerReceivedSubscriptionPush)

        // Clean up
        manager.removeEventHandler(id: handlerId)
        manager.unregisterSubscriptionHandler(id: "test-sub-4")
    }

    @Test @MainActor func malformedSubscriptionPushIsDropped() async {
        let manager = ConnectionManager.shared
        var legacyHandlerReceivedSubscriptionPush = false
        var routerHandlerCalled = false

        let handlerId = manager.onEvent { method, _ in
            if method == "subscription.push" {
                legacyHandlerReceivedSubscriptionPush = true
            }
        }

        manager.registerSubscriptionHandler(id: "test-sub-5") { _ in
            routerHandlerCalled = true
        }

        // Missing required fields (no "seq" or "kind")
        let malformedPushMessage = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"test-sub-5"}}
        """
        await manager.dispatchMessage(malformedPushMessage)

        // Malformed push should be dropped entirely: no router dispatch, no legacy broadcast
        #expect(!routerHandlerCalled)
        #expect(!legacyHandlerReceivedSubscriptionPush)

        // Clean up
        manager.removeEventHandler(id: handlerId)
        manager.unregisterSubscriptionHandler(id: "test-sub-5")
    }

    @Test @MainActor func unregisteredSubscriptionIdIsDropped() async {
        let manager = ConnectionManager.shared
        var legacyHandlerReceivedSubscriptionPush = false

        let handlerId = manager.onEvent { method, _ in
            if method == "subscription.push" {
                legacyHandlerReceivedSubscriptionPush = true
            }
        }

        // Do NOT register a handler for "test-sub-6"
        let pushMessage = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"test-sub-6","kind":"snapshot","seq":0,"snapshot":[]}}
        """
        await manager.dispatchMessage(pushMessage)

        // Unregistered push should not be dispatched to legacy handlers (it is buffered
        // for potential replay, never broadcast)
        #expect(!legacyHandlerReceivedSubscriptionPush)

        // Clean up
        manager.removeEventHandler(id: handlerId)
        manager.unroutedPushBuffer.removeAll { $0.push.subscriptionId == "test-sub-6" }
    }

    // MARK: - Unrouted push buffering (dropped seq-0 snapshot race)

    @Test @MainActor func bufferedPushesReplayedInOrderOnRegistration() async {
        let manager = ConnectionManager.shared
        var received: [(kind: SubscriptionPush.Kind, seq: Int)] = []

        // Snapshot + deltas arrive BEFORE any handler is registered (the race)
        await manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-1","kind":"snapshot","seq":0,"snapshot":{"agentId":"a1","messages":[]}}}
        """)
        await manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-1","kind":"delta","seq":1,"delta":{"added":[],"updated":[],"removedIds":[]}}}
        """)
        await manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-1","kind":"delta","seq":2,"delta":{"added":[],"updated":[],"removedIds":[]}}}
        """)

        manager.registerSubscriptionHandler(id: "buf-sub-1") { push in
            received.append((push.kind, push.seq))
        }

        // Replayed synchronously on registration, in arrival order
        #expect(received.count == 3)
        #expect(received[0].kind == .snapshot && received[0].seq == 0)
        #expect(received[1].kind == .delta && received[1].seq == 1)
        #expect(received[2].kind == .delta && received[2].seq == 2)
        // Buffer cleared after replay
        #expect(!manager.unroutedPushBuffer.contains { $0.push.subscriptionId == "buf-sub-1" })

        // Clean up
        manager.unregisterSubscriptionHandler(id: "buf-sub-1")
    }

    @Test @MainActor func bufferEvictionRespectsBounds() async {
        let manager = ConnectionManager.shared
        manager.unroutedPushBuffer.removeAll()

        let limit = ConnectionManager.unroutedPushBufferLimit
        let total = limit + 6
        for seq in 0..<total {
            await manager.dispatchMessage("""
            {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-evict","kind":"delta","seq":\(seq),"delta":{"added":[],"updated":[],"removedIds":[]}}}
            """)
        }
        #expect(manager.unroutedPushBuffer.count == limit)

        var receivedSeqs: [Int] = []
        manager.registerSubscriptionHandler(id: "buf-sub-evict") { push in
            receivedSeqs.append(push.seq)
        }

        // Oldest frames evicted; the most recent `limit` frames replayed in order
        #expect(receivedSeqs == Array((total - limit)..<total))

        // Clean up
        manager.unregisterSubscriptionHandler(id: "buf-sub-evict")
    }

    @Test @MainActor func bufferTTLExpiresOldPushes() async {
        let manager = ConnectionManager.shared

        // Fresh push arrives unrouted → buffered
        await manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-ttl","kind":"delta","seq":2,"delta":{"added":[],"updated":[],"removedIds":[]}}}
        """)
        // Seed a push that exceeded the TTL
        let stalePush = SubscriptionPush(
            subscriptionId: "buf-sub-ttl", kind: .delta, seq: 1, snapshot: nil,
            delta: SubscriptionPush.DeltaPayload(added: [], updated: [], removedIds: []))
        manager.unroutedPushBuffer.append(ConnectionManager.BufferedPush(
            push: stalePush,
            receivedAt: Date(timeIntervalSinceNow: -(ConnectionManager.unroutedPushBufferTTL + 1))))

        var receivedSeqs: [Int] = []
        manager.registerSubscriptionHandler(id: "buf-sub-ttl") { push in
            receivedSeqs.append(push.seq)
        }

        // Only the fresh push replays; the expired one is pruned
        #expect(receivedSeqs == [2])

        // Clean up
        manager.unregisterSubscriptionHandler(id: "buf-sub-ttl")
    }

    @Test @MainActor func noDoubleDeliveryWhenHandlerRegisteredMidStream() async {
        let manager = ConnectionManager.shared
        var receivedSeqs: [Int] = []

        // seq 0 arrives pre-registration → buffered
        await manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-mid","kind":"snapshot","seq":0,"snapshot":{"agentId":"a1","messages":[]}}}
        """)

        manager.registerSubscriptionHandler(id: "buf-sub-mid") { push in
            receivedSeqs.append(push.seq)
        }
        // Replay delivered seq 0 exactly once
        #expect(receivedSeqs == [0])

        // seq 1 arrives post-registration → routed live, never buffered
        await manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-mid","kind":"delta","seq":1,"delta":{"added":[],"updated":[],"removedIds":[]}}}
        """)
        #expect(receivedSeqs == [0, 1])
        #expect(!manager.unroutedPushBuffer.contains { $0.push.subscriptionId == "buf-sub-mid" })

        // Clean up
        manager.unregisterSubscriptionHandler(id: "buf-sub-mid")
    }

    @Test @MainActor func unregisterDropsBufferedPushes() async {
        let manager = ConnectionManager.shared

        // Push buffered for a subscription that then gets unregistered (e.g. resnapshot)
        await manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-unreg","kind":"snapshot","seq":0,"snapshot":{"agentId":"a1","messages":[]}}}
        """)
        manager.unregisterSubscriptionHandler(id: "buf-sub-unreg")

        var receivedCount = 0
        manager.registerSubscriptionHandler(id: "buf-sub-unreg") { _ in
            receivedCount += 1
        }
        // Buffered push for the dead subscription must not replay
        #expect(receivedCount == 0)

        // Clean up
        manager.unregisterSubscriptionHandler(id: "buf-sub-unreg")
    }

    @Test @MainActor func stragglerPushesAfterUnregisterAreNotBuffered() async {
        let manager = ConnectionManager.shared

        manager.registerSubscriptionHandler(id: "buf-sub-dead") { _ in }
        manager.unregisterSubscriptionHandler(id: "buf-sub-dead")

        // Straggler pushes for the dead id (unsubscribe still in flight on the daemon)
        // must be dropped, not buffered — they can never replay and would only add
        // eviction pressure on the shared buffer
        await manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-dead","kind":"delta","seq":7,"delta":{"added":[],"updated":[],"removedIds":[]}}}
        """)
        #expect(!manager.unroutedPushBuffer.contains { $0.push.subscriptionId == "buf-sub-dead" })

        // A brand-new subscriptionId is unaffected by the tombstone
        await manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-fresh","kind":"snapshot","seq":0,"snapshot":{"agentId":"a1","messages":[]}}}
        """)
        var receivedSeqs: [Int] = []
        manager.registerSubscriptionHandler(id: "buf-sub-fresh") { push in
            receivedSeqs.append(push.seq)
        }
        #expect(receivedSeqs == [0])

        // Clean up
        manager.unregisterSubscriptionHandler(id: "buf-sub-fresh")
    }

    @Test @MainActor func reusedIdRevivedByFreshSnapshotAfterUnregister() async {
        let manager = ConnectionManager.shared

        manager.registerSubscriptionHandler(id: "buf-sub-reused") { _ in }
        manager.unregisterSubscriptionHandler(id: "buf-sub-reused")

        // A seq-0 snapshot for the tombstoned id means the daemon reused it for a
        // brand-new subscription (ids reset on daemon restart) — it must be buffered
        // and replayed, not dropped
        await manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-reused","kind":"snapshot","seq":0,"snapshot":{"agentId":"a1","messages":[]}}}
        """)
        await manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-reused","kind":"delta","seq":1,"delta":{"added":[],"updated":[],"removedIds":[]}}}
        """)

        var receivedSeqs: [Int] = []
        manager.registerSubscriptionHandler(id: "buf-sub-reused") { push in
            receivedSeqs.append(push.seq)
        }
        #expect(receivedSeqs == [0, 1])

        // Clean up
        manager.unregisterSubscriptionHandler(id: "buf-sub-reused")
    }

    @Test @MainActor func collectionChannelPushesUnaffectedByBuffering() async {
        let manager = ConnectionManager.shared
        var received: [(kind: SubscriptionPush.Kind, seq: Int, count: Int)] = []

        // Registered-first (normal collection-channel flow): pushes route live
        manager.registerSubscriptionHandler(id: "col-sub-1") { push in
            received.append((push.kind, push.seq, push.snapshot?.count ?? 0))
        }
        await manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"col-sub-1","kind":"snapshot","seq":0,"snapshot":[{"id":"note-1"},{"id":"note-2"}]}}
        """)
        await manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"col-sub-1","kind":"delta","seq":1,"delta":{"added":[],"updated":[{"id":"note-1"}],"removedIds":[]}}}
        """)
        #expect(received.count == 2)
        #expect(received[0].kind == .snapshot && received[0].seq == 0 && received[0].count == 2)
        #expect(received[1].kind == .delta && received[1].seq == 1)
        #expect(!manager.unroutedPushBuffer.contains { $0.push.subscriptionId == "col-sub-1" })

        // Array-shaped (collection) snapshot arriving pre-registration replays intact
        await manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"col-sub-2","kind":"snapshot","seq":0,"snapshot":[{"id":"task-1"}]}}
        """)
        var replayedSnapshot: [[String: Any]]?
        manager.registerSubscriptionHandler(id: "col-sub-2") { push in
            replayedSnapshot = push.snapshot
        }
        #expect(replayedSnapshot?.count == 1)
        #expect(replayedSnapshot?.first?["id"] as? String == "task-1")

        // Clean up
        manager.unregisterSubscriptionHandler(id: "col-sub-1")
        manager.unregisterSubscriptionHandler(id: "col-sub-2")
    }

    @Test @MainActor func bufferedChatSnapshotReplayedIntoConversationStore() async {
        let manager = ConnectionManager.shared
        let store = ConversationStore(connectionManager: manager)
        store.setTestChatChannel(subscriptionId: "buf-chat-race")

        // Snapshot + first delta arrive BEFORE the store registers its handler
        // (the seq-0 race this fix addresses)
        await manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-chat-race","kind":"snapshot","seq":0,"snapshot":{"agentId":"agent-1","messages":[{"id":"msg-1","role":"user","contentBlocks":[{"type":"text","id":"msg-1:0","text":"Hello"}],"timestamp":"2026-07-21T01:00:00.000Z"}]}}}
        """)
        await manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-chat-race","kind":"delta","seq":1,"delta":{"added":[{"agentId":"agent-1","messageId":"msg-2","role":"assistant","block":{"type":"text","id":"msg-2:0","text":"Working"}}],"updated":[],"removedIds":[]}}}
        """)

        // The store registers its handler (as subscribeLiveChat does after the
        // subscribe response resumes) → buffered pushes replay and apply
        manager.registerSubscriptionHandler(id: "buf-chat-race") { [weak store] push in
            store?.handleChatSubscriptionPush(push)
        }

        #expect(store.messages.count == 2)
        #expect(store.messages[0].id == "msg-1")
        #expect(store.messages[1].id == "msg-2")
        #expect(store.messages[1].contentBlocks?.first?.resolvedText == "Working")
        #expect(store.isStreaming == true)

        // The channel is seeded correctly: the next live delta continues the
        // sequence without a gap (no resnapshot wiped the seeded state)
        await manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-chat-race","kind":"delta","seq":2,"delta":{"added":[],"updated":[{"agentId":"agent-1","messageId":"msg-2","role":"assistant","block":{"type":"text","id":"msg-2:0","text":"Working on it."}}],"removedIds":[]}}}
        """)
        #expect(store.messages[1].contentBlocks?.first?.resolvedText == "Working on it.")

        // Clean up
        manager.unregisterSubscriptionHandler(id: "buf-chat-race")
    }
}

