import Combine
import Foundation
@testable import Intent
import Testing

@MainActor
struct FakeConnectionManagerTests {
    // MARK: - Connection State

    @Test func connectionStatePublisher() async {
        let fake = FakeConnectionManager()
        var states: [ConnectionState] = []
        let cancellable = fake.connectionStatePublisher.sink { state in
            states.append(state)
        }

        #expect(states == [.disconnected])

        fake.simulateConnect()
        #expect(fake.connectionState == .connected)
        #expect(states == [.disconnected, .connected])

        fake.simulateDisconnect()
        #expect(fake.connectionState == .disconnected)
        #expect(states == [.disconnected, .connected, .disconnected])

        cancellable.cancel()
    }

    @Test func connectionLogsPreserveNamedFieldsAndOrder() async throws {
        let fake = FakeConnectionManager()

        try await fake.connect(
            hosts: ["first.example"],
            port: 1111,
            token: "first-token",
            certFingerprint: "first-cert",
            tcAddress: nil
        )
        try await fake.connect(
            hosts: ["second.example"],
            port: 2222,
            token: "second-token",
            certFingerprint: nil,
            tcAddress: "tailnet.example"
        )
        fake.updateCachedCredentials(
            hosts: ["cached.example"],
            port: 3333,
            token: "cached-token",
            certFingerprint: "cached-cert",
            tcAddress: "cached-tailnet.example"
        )

        #expect(fake.connectLog.map(\.hosts) == [["first.example"], ["second.example"]])
        #expect(fake.connectLog.map(\.port) == [1111, 2222])
        #expect(fake.connectLog.map(\.token) == ["first-token", "second-token"])
        #expect(fake.connectLog.map(\.certFingerprint) == ["first-cert", nil])
        #expect(fake.connectLog.map(\.tcAddress) == [nil, "tailnet.example"])
        #expect(fake.updateCachedCredentialsLog.first?.hosts == ["cached.example"])
        #expect(fake.updateCachedCredentialsLog.first?.port == 3333)
        #expect(fake.updateCachedCredentialsLog.first?.token == "cached-token")
        #expect(fake.updateCachedCredentialsLog.first?.certFingerprint == "cached-cert")
        #expect(fake.updateCachedCredentialsLog.first?.tcAddress == "cached-tailnet.example")
    }

    // MARK: - Request/Response Mocking

    @Test func requestReturnsConfiguredResponse() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["test.method"] = ["result": "success"]

        let result = try await fake.request("test.method", params: [:])
        guard let dict = result as? [String: String] else {
            Issue.record("Expected dictionary response")
            return
        }
        #expect(dict["result"] == "success")
    }

    @Test func requestThrowsConfiguredError() async throws {
        let fake = FakeConnectionManager()
        let expectedError = NSError(domain: "Test", code: 42, userInfo: nil)
        fake.errorMap["failing.method"] = expectedError

        do {
            _ = try await fake.request("failing.method", params: [:])
            Issue.record("Expected error to be thrown")
        } catch let error as NSError {
            #expect(error.domain == "Test")
            #expect(error.code == 42)
        }
    }

    @Test func requestThrowsForUnconfiguredMethod() async {
        let fake = FakeConnectionManager()

        do {
            _ = try await fake.request("unconfigured.method", params: [:])
            Issue.record("Expected error for unconfigured method")
        } catch {
            // Expected
        }
    }

    @Test func requestLogRecordsAllCalls() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["method1"] = "ok"
        fake.responseMap["method2"] = "ok"

        let beforeRequests = Date()
        _ = try await fake.request("method1", params: ["a": 1])
        _ = try await fake.request("method2", params: ["b": 2])
        let afterRequests = Date()

        #expect(fake.requestLog.count == 2)
        #expect(fake.requestLog[0].method == "method1")
        #expect(fake.requestLog[0].params["a"] as? Int == 1)
        #expect(fake.requestLog[1].method == "method2")
        #expect(fake.requestLog[1].params["b"] as? Int == 2)
        #expect(fake.requestLog[0].timestamp >= beforeRequests)
        #expect(fake.requestLog[0].timestamp <= fake.requestLog[1].timestamp)
        #expect(fake.requestLog[1].timestamp <= afterRequests)
        #expect(fake.didCallMethod("method1"))
        #expect(fake.didCallMethod("method2"))
        #expect(!fake.didCallMethod("method3"))
    }

    // MARK: - Legacy Event Handlers

    @Test func legacyEventHandlerRegistration() async {
        let fake = FakeConnectionManager()

        var receivedEvents: [(String, Any)] = []
        let handlerId = fake.onEvent { method, params in
            receivedEvents.append((method, params))
        }

        #expect(fake.eventHandlerCount == 1)

        fake.deliverEvent(method: "note.updated", params: ["noteId": "note-1"])
        #expect(receivedEvents.count == 1)
        #expect(receivedEvents[0].0 == "note.updated")

        fake.removeEventHandler(id: handlerId)
        #expect(fake.eventHandlerCount == 0)

        fake.deliverEvent(method: "note.deleted", params: ["noteId": "note-2"])
        #expect(receivedEvents.count == 1) // No new event received after removal
    }

    // MARK: - Subscription Push Routing

    @Test func subscriptionHandlerRegistrationAndDelivery() async {
        let fake = FakeConnectionManager()

        var receivedPushes: [SubscriptionPush] = []
        fake.registerSubscriptionHandler(id: "sub-123") { push in
            receivedPushes.append(push)
        }

        #expect(fake.hasSubscriptionHandler(id: "sub-123"))
        #expect(fake.subscriptionHandlerCount == 1)

        let push = SubscriptionPush(
            subscriptionId: "sub-123",
            seq: 0,
            snapshot: [["id": "1"]],
        )

        fake.deliverSubscriptionPush(push)
        #expect(receivedPushes.count == 1)
        #expect(receivedPushes[0].subscriptionId == "sub-123")
        #expect(receivedPushes[0].seq == 0)
    }

    @Test func subscriptionPushOnlyReachesRegisteredHandler() async {
        let fake = FakeConnectionManager()

        var receivedA: [SubscriptionPush] = []
        var receivedB: [SubscriptionPush] = []

        fake.registerSubscriptionHandler(id: "sub-A") { push in
            receivedA.append(push)
        }
        fake.registerSubscriptionHandler(id: "sub-B") { push in
            receivedB.append(push)
        }

        let pushA = SubscriptionPush(subscriptionId: "sub-A", seq: 0, snapshot: [])
        let pushB = SubscriptionPush(subscriptionId: "sub-B", seq: 0, snapshot: [])

        fake.deliverSubscriptionPush(pushA)
        #expect(receivedA.count == 1)
        #expect(receivedB.isEmpty)

        fake.deliverSubscriptionPush(pushB)
        #expect(receivedA.count == 1)
        #expect(receivedB.count == 1)
    }

    // MARK: - Bounded condition waits (ios#261)

    @Test func waitUntilThrowsOnTimeoutInsteadOfContinuing() async {
        await #expect(throws: ConditionWaitFailure.self) {
            try await waitUntil("a condition that never holds", timeout: .milliseconds(20)) { false }
        }
    }

    @Test func expectNeverThrowsWhenTheForbiddenConditionAppearsInsideTheWindow() async {
        let fake = FakeConnectionManager()
        fake.responseMap["agent.markSeen"] = ["success": true] as [String: Any]
        Task { _ = try? await fake.request("agent.markSeen") }

        await #expect(throws: ConditionWaitFailure.self) {
            try await expectNever("agent.markSeen RPC") { fake.didCallMethod("agent.markSeen") }
        }
    }

    @Test func waitForPendingRequestsObservesTheParkedContinuation() async throws {
        let fake = FakeConnectionManager()
        fake.pendingMethods.insert("agent.get")
        let request = Task { try await fake.request("agent.get") is [String: Any] }

        try await fake.waitForPendingRequests("agent.get")
        #expect(fake.pendingRequestCount("agent.get") == 1)

        fake.resolvePending("agent.get", with: ["ok": true] as [String: Any])
        #expect(try await request.value)
        #expect(fake.pendingRequestCount("agent.get") == 0)
    }
}
