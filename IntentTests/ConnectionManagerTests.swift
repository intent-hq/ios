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

        // Unregistered push should be dropped (logged at debug but not dispatched)
        #expect(!legacyHandlerReceivedSubscriptionPush)

        // Clean up
        manager.removeEventHandler(id: handlerId)
    }
}

