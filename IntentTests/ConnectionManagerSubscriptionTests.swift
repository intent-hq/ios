import Combine
import Foundation
@testable import Intent
import Network
import os
import Testing

extension ConnectionManagerTests {
    // MARK: - Subscription Push Routing

    @Test @MainActor func registerSubscriptionHandlerStoresHandler() {
        let manager = ConnectionManager.shared
        var receivedPush: SubscriptionPush?

        manager.registerSubscriptionHandler(id: "test-sub-1") { push in
            receivedPush = push
        }

        let pushMessage = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"test-sub-1","kind":"snapshot","seq":0,"snapshot":[]}}
        """
        manager.dispatchMessage(pushMessage)

        #expect(receivedPush != nil)
        #expect(receivedPush?.subscriptionId == "test-sub-1")
        #expect(receivedPush?.kind == .snapshot)

        manager.unregisterSubscriptionHandler(id: "test-sub-1")
    }

    @Test @MainActor func unregisterRemovesHandler() {
        let manager = ConnectionManager.shared
        var receivedCount = 0

        manager.registerSubscriptionHandler(id: "test-sub-2") { _ in
            receivedCount += 1
        }

        let pushMessage = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"test-sub-2","kind":"snapshot","seq":0,"snapshot":[]}}
        """

        manager.dispatchMessage(pushMessage)
        #expect(receivedCount == 1)

        manager.unregisterSubscriptionHandler(id: "test-sub-2")

        manager.dispatchMessage(pushMessage)
        #expect(receivedCount == 1)
    }

    @Test @MainActor func disconnectClearsSubscriptionHandlers() {
        let manager = ConnectionManager.shared
        var receivedCount = 0

        manager.registerSubscriptionHandler(id: "disc-sub-1") { _ in
            receivedCount += 1
        }
        #expect(manager.subscriptionHandlerCount >= 1)

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

        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"disc-sub-1","kind":"snapshot","seq":0,"snapshot":[]}}
        """)
        #expect(receivedCount == 0)

        manager.unregisterSubscriptionHandler(id: "disc-sub-1")
    }

    @Test @MainActor func twoHandlersOnlyReceiveTheirOwnPushes() {
        let manager = ConnectionManager.shared
        var receivedPush1: SubscriptionPush?
        var receivedPush2: SubscriptionPush?

        manager.registerSubscriptionHandler(id: "test-sub-a") { push in
            receivedPush1 = push
        }

        manager.registerSubscriptionHandler(id: "test-sub-b") { push in
            receivedPush2 = push
        }

        let pushA = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"test-sub-a","kind":"snapshot","seq":1,"snapshot":[]}}
        """
        manager.dispatchMessage(pushA)

        #expect(receivedPush1?.subscriptionId == "test-sub-a")
        #expect(receivedPush1?.seq == 1)
        #expect(receivedPush2 == nil)

        receivedPush1 = nil
        receivedPush2 = nil

        let pushB = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"test-sub-b","kind":"snapshot","seq":2,"snapshot":[]}}
        """
        manager.dispatchMessage(pushB)

        #expect(receivedPush1 == nil)
        #expect(receivedPush2?.subscriptionId == "test-sub-b")
        #expect(receivedPush2?.seq == 2)

        manager.unregisterSubscriptionHandler(id: "test-sub-a")
        manager.unregisterSubscriptionHandler(id: "test-sub-b")
    }

    @Test @MainActor func reregisterSameIdReplacesHandler() {
        let manager = ConnectionManager.shared
        var firstHandlerCalled = false
        var secondHandlerCalled = false

        manager.registerSubscriptionHandler(id: "test-sub-3") { _ in
            firstHandlerCalled = true
        }

        manager.registerSubscriptionHandler(id: "test-sub-3") { _ in
            secondHandlerCalled = true
        }

        let pushMessage = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"test-sub-3","kind":"snapshot","seq":0,"snapshot":[]}}
        """
        manager.dispatchMessage(pushMessage)

        #expect(!firstHandlerCalled)
        #expect(secondHandlerCalled)

        manager.unregisterSubscriptionHandler(id: "test-sub-3")
    }

    @Test @MainActor func subscriptionPushDoesNotReachLegacyEventHandlers() {
        let manager = ConnectionManager.shared
        var legacyHandlerReceivedSubscriptionPush = false
        var routerHandlerReceivedPush = false

        let handlerId = manager.onEvent { method, _ in
            if method == "subscription.push" {
                legacyHandlerReceivedSubscriptionPush = true
            }
        }

        manager.registerSubscriptionHandler(id: "test-sub-4") { _ in
            routerHandlerReceivedPush = true
        }

        let pushMessage = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"test-sub-4","kind":"snapshot","seq":0,"snapshot":[]}}
        """
        manager.dispatchMessage(pushMessage)

        #expect(routerHandlerReceivedPush)
        #expect(!legacyHandlerReceivedSubscriptionPush)

        manager.removeEventHandler(id: handlerId)
        manager.unregisterSubscriptionHandler(id: "test-sub-4")
    }

    @Test @MainActor func malformedSubscriptionPushIsDropped() {
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

        let malformedPushMessage = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"test-sub-5"}}
        """
        manager.dispatchMessage(malformedPushMessage)

        #expect(!routerHandlerCalled)
        #expect(!legacyHandlerReceivedSubscriptionPush)

        manager.removeEventHandler(id: handlerId)
        manager.unregisterSubscriptionHandler(id: "test-sub-5")
    }
}

extension ConnectionManagerTests {
    @Test @MainActor func unregisteredSubscriptionIdIsDropped() {
        let manager = ConnectionManager.shared
        var legacyHandlerReceivedSubscriptionPush = false

        let handlerId = manager.onEvent { method, _ in
            if method == "subscription.push" {
                legacyHandlerReceivedSubscriptionPush = true
            }
        }

        let pushMessage = """
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"test-sub-6","kind":"snapshot","seq":0,"snapshot":[]}}
        """
        manager.dispatchMessage(pushMessage)

        #expect(!legacyHandlerReceivedSubscriptionPush)

        manager.removeEventHandler(id: handlerId)
        manager.unregisterSubscriptionHandler(id: "test-sub-6")
    }

    // MARK: - Unrouted push buffering (dropped seq-0 snapshot race)

    @Test @MainActor func bufferedPushesReplayedInOrderOnRegistration() {
        let manager = ConnectionManager.shared
        var received: [(kind: SubscriptionPush.Kind, seq: Int)] = []

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

        #expect(received.count == 3)
        #expect(received[0].kind == .snapshot && received[0].seq == 0)
        #expect(received[1].kind == .delta && received[1].seq == 1)
        #expect(received[2].kind == .delta && received[2].seq == 2)
        #expect(!manager.hasBufferedSubscriptionPush(for: "buf-sub-1"))

        manager.unregisterSubscriptionHandler(id: "buf-sub-1")
    }

    @Test @MainActor func bufferEvictionRespectsBounds() {
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

        #expect(receivedSeqs == Array((total - limit)..<total))

        manager.unregisterSubscriptionHandler(id: "buf-sub-evict")
    }

    @Test @MainActor func bufferTTLExpiresOldPushes() {
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

        #expect(receivedSeqs == [2])

        router.unregister(id: "buf-sub-ttl")
    }

    @Test @MainActor func noDoubleDeliveryWhenHandlerRegisteredMidStream() {
        let manager = ConnectionManager.shared
        var receivedSeqs: [Int] = []

        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-mid","kind":"snapshot","seq":0,"snapshot":{"agentId":"a1","messages":[]}}}
        """)

        manager.registerSubscriptionHandler(id: "buf-sub-mid") { push in
            receivedSeqs.append(push.seq)
        }
        #expect(receivedSeqs == [0])

        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-mid","kind":"delta","seq":1,"delta":{"added":[],"updated":[],"removedIds":[]}}}
        """)
        #expect(receivedSeqs == [0, 1])
        #expect(!manager.hasBufferedSubscriptionPush(for: "buf-sub-mid"))

        manager.unregisterSubscriptionHandler(id: "buf-sub-mid")
    }

    @Test @MainActor func unregisterDropsBufferedPushes() {
        let manager = ConnectionManager.shared

        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-unreg","kind":"snapshot","seq":0,"snapshot":{"agentId":"a1","messages":[]}}}
        """)
        manager.unregisterSubscriptionHandler(id: "buf-sub-unreg")

        var receivedCount = 0
        manager.registerSubscriptionHandler(id: "buf-sub-unreg") { _ in
            receivedCount += 1
        }
        #expect(receivedCount == 0)

        manager.unregisterSubscriptionHandler(id: "buf-sub-unreg")
    }

    @Test @MainActor func stragglerPushesAfterUnregisterAreNotBuffered() {
        let manager = ConnectionManager.shared

        manager.registerSubscriptionHandler(id: "buf-sub-dead") { _ in }
        manager.unregisterSubscriptionHandler(id: "buf-sub-dead")

        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-dead","kind":"delta","seq":7,"delta":{"added":[],"updated":[],"removedIds":[]}}}
        """)
        #expect(!manager.hasBufferedSubscriptionPush(for: "buf-sub-dead"))

        manager.dispatchMessage("""
        {"jsonrpc":"2.0","method":"subscription.push","params":{"subscriptionId":"buf-sub-fresh","kind":"snapshot","seq":0,"snapshot":{"agentId":"a1","messages":[]}}}
        """)
        var receivedSeqs: [Int] = []
        manager.registerSubscriptionHandler(id: "buf-sub-fresh") { push in
            receivedSeqs.append(push.seq)
        }
        #expect(receivedSeqs == [0])

        manager.unregisterSubscriptionHandler(id: "buf-sub-fresh")
    }

    @Test @MainActor func reusedIdRevivedByFreshSnapshotAfterUnregister() {
        let manager = ConnectionManager.shared

        manager.registerSubscriptionHandler(id: "buf-sub-reused") { _ in }
        manager.unregisterSubscriptionHandler(id: "buf-sub-reused")

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

        manager.unregisterSubscriptionHandler(id: "buf-sub-reused")
    }
}
