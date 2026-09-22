import Combine
import Foundation
@testable import Intent
import Network
import os
import Testing

extension ConnectionManagerTests {
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
        manager.dispatchMessage(pushMessage)

        #expect(receivedPush != nil)
        #expect(receivedPush?.subscriptionId == "test-sub-1")
        #expect(receivedPush?.kind == .snapshot)

        // Clean up
        manager.unregisterSubscriptionHandler(id: "test-sub-1")
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
        manager.dispatchMessage(pushMessage)
        #expect(receivedCount == 1)

        // Unregister
        manager.unregisterSubscriptionHandler(id: "test-sub-2")

        // Second push should be dropped
        manager.dispatchMessage(pushMessage)
        #expect(receivedCount == 1) // Still 1, not incremented
    }

    // Subscriptions are per-connection (PROTOCOL §6.1, monorepo#2213): disconnect
    // must drop all registered subscription handlers, buffered unrouted pushes, and
    // unregister tombstones — ids can be reused after a daemon restart, so stale
    // prior-connection buffer/tombstone state must not leak into the next connection.
    @Test @MainActor func disconnectClearsSubscriptionHandlers() async {
        let manager = ConnectionManager.shared
        var receivedCount = 0

        manager.registerSubscriptionHandler(id: "disc-sub-1") { _ in
            receivedCount += 1
        }
        #expect(manager.subscriptionHandlerCount >= 1)

        // Seed per-connection buffer + tombstone state: an unrouted push for an
        // unregistered id gets buffered, and unregistering lays a tombstone.
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"disc-sub-buffered","kind":"snapshot","seq":0,"snapshot":[]}}
        """)
        manager.unregisterSubscriptionHandler(id: "disc-sub-tombstoned")
        #expect(manager.hasBufferedSubscriptionPush(for: "disc-sub-buffered"))
        #expect(manager.hasRecentlyUnregisteredSubscription(id: "disc-sub-tombstoned"))

        manager.disconnect()
        #expect(manager.subscriptionHandlerCount == 0)
        #expect(!manager.hasBufferedSubscriptionPush(for: "disc-sub-buffered"))
        #expect(!manager.hasRecentlyUnregisteredSubscription(id: "disc-sub-tombstoned"))

        // A push for the cleared id no longer reaches the handler
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"disc-sub-1","kind":"snapshot","seq":0,"snapshot":[]}}
        """)
        #expect(receivedCount == 0)

        // Clean up: the unrouted push above was buffered for replay; drop it
        manager.unregisterSubscriptionHandler(id: "disc-sub-1")
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
        manager.dispatchMessage(pushA)

        #expect(receivedPush1?.subscriptionId == "test-sub-a")
        #expect(receivedPush1?.seq == 1)
        #expect(receivedPush2 == nil) // Handler B should not receive A's push

        // Reset and send push for subscription B
        receivedPush1 = nil
        receivedPush2 = nil

        let pushB = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"test-sub-b","kind":"snapshot","seq":2,"snapshot":[]}}
        """
        manager.dispatchMessage(pushB)

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
        manager.dispatchMessage(pushMessage)

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
        manager.dispatchMessage(pushMessage)

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
        manager.dispatchMessage(malformedPushMessage)

        // Malformed push should be dropped entirely: no router dispatch, no legacy broadcast
        #expect(!routerHandlerCalled)
        #expect(!legacyHandlerReceivedSubscriptionPush)

        // Clean up
        manager.removeEventHandler(id: handlerId)
        manager.unregisterSubscriptionHandler(id: "test-sub-5")
    }
}

extension ConnectionManagerTests {
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
        manager.dispatchMessage(pushMessage)

        // Unregistered push should not be dispatched to legacy handlers (it is buffered
        // for potential replay, never broadcast)
        #expect(!legacyHandlerReceivedSubscriptionPush)

        // Clean up
        manager.removeEventHandler(id: handlerId)
        manager.unregisterSubscriptionHandler(id: "test-sub-6")
    }

    // MARK: - Unrouted push buffering (dropped seq-0 snapshot race)

    @Test @MainActor func bufferedPushesReplayedInOrderOnRegistration() async {
        let manager = ConnectionManager.shared
        var received: [(kind: SubscriptionPush.Kind, seq: Int)] = []

        // Snapshot + deltas arrive BEFORE any handler is registered (the race)
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-1","kind":"snapshot","seq":0,"snapshot":{"agentId":"a1","messages":[]}}}
        """)
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-1","kind":"delta","seq":1,"delta":{"added":[],"updated":[],"removedIds":[]}}}
        """)
        manager.dispatchMessage("""
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
        #expect(!manager.hasBufferedSubscriptionPush(for: "buf-sub-1"))

        // Clean up
        manager.unregisterSubscriptionHandler(id: "buf-sub-1")
    }

    @Test @MainActor func bufferEvictionRespectsBounds() async {
        let manager = ConnectionManager.shared
        manager.disconnect()

        let limit = ConnectionSubscriptionRouter.defaultBufferLimit
        let total = limit + 6
        for seq in 0..<total {
            manager.dispatchMessage("""
            {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-evict","kind":"delta","seq":\(seq),"delta":{"added":[],"updated":[],"removedIds":[]}}}
            """)
        }
        #expect(manager.bufferedSubscriptionPushCount == limit)

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
        var currentDate = Date()
        let router = ConnectionSubscriptionRouter { currentDate }
        let delta: [String: Any] = ["added": [], "updated": [], "removedIds": []]

        _ = router.route(method: "subscription.push", params: [
            "subscriptionId": "buf-sub-ttl",
            "kind": "delta",
            "seq": 1,
            "delta": delta
        ])
        currentDate.addTimeInterval(ConnectionSubscriptionRouter.defaultBufferTTL + 1)
        _ = router.route(method: "subscription.push", params: [
            "subscriptionId": "buf-sub-ttl",
            "kind": "delta",
            "seq": 2,
            "delta": delta
        ])

        var receivedSeqs: [Int] = []
        router.register(id: "buf-sub-ttl") { push in
            receivedSeqs.append(push.seq)
        }

        // Only the fresh push replays; the expired one is pruned
        #expect(receivedSeqs == [2])

        router.unregister(id: "buf-sub-ttl")
    }

    @Test @MainActor func noDoubleDeliveryWhenHandlerRegisteredMidStream() async {
        let manager = ConnectionManager.shared
        var receivedSeqs: [Int] = []

        // seq 0 arrives pre-registration → buffered
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-mid","kind":"snapshot","seq":0,"snapshot":{"agentId":"a1","messages":[]}}}
        """)

        manager.registerSubscriptionHandler(id: "buf-sub-mid") { push in
            receivedSeqs.append(push.seq)
        }
        // Replay delivered seq 0 exactly once
        #expect(receivedSeqs == [0])

        // seq 1 arrives post-registration → routed live, never buffered
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-mid","kind":"delta","seq":1,"delta":{"added":[],"updated":[],"removedIds":[]}}}
        """)
        #expect(receivedSeqs == [0, 1])
        #expect(!manager.hasBufferedSubscriptionPush(for: "buf-sub-mid"))

        // Clean up
        manager.unregisterSubscriptionHandler(id: "buf-sub-mid")
    }

    @Test @MainActor func unregisterDropsBufferedPushes() async {
        let manager = ConnectionManager.shared

        // Push buffered for a subscription that then gets unregistered (e.g. resnapshot)
        manager.dispatchMessage("""
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
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-dead","kind":"delta","seq":7,"delta":{"added":[],"updated":[],"removedIds":[]}}}
        """)
        #expect(!manager.hasBufferedSubscriptionPush(for: "buf-sub-dead"))

        // A brand-new subscriptionId is unaffected by the tombstone
        manager.dispatchMessage("""
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
        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-reused","kind":"snapshot","seq":0,"snapshot":{"agentId":"a1","messages":[]}}}
        """)
        manager.dispatchMessage("""
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
}
