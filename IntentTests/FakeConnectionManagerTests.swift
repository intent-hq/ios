import Foundation
import Testing
import Combine
@testable import Intent

@MainActor
struct FakeConnectionManagerTests {
    
    // MARK: - Connection State
    
    @Test func connectionStatePublisher() async throws {
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
            let _ = try await fake.request("failing.method", params: [:])
            Issue.record("Expected error to be thrown")
        } catch let error as NSError {
            #expect(error.domain == "Test")
            #expect(error.code == 42)
        }
    }
    
    @Test func requestThrowsForUnconfiguredMethod() async throws {
        let fake = FakeConnectionManager()
        
        do {
            let _ = try await fake.request("unconfigured.method", params: [:])
            Issue.record("Expected error for unconfigured method")
        } catch {
            // Expected
        }
    }
    
    @Test func requestLogRecordsAllCalls() async throws {
        let fake = FakeConnectionManager()
        fake.responseMap["method1"] = "ok"
        fake.responseMap["method2"] = "ok"
        
        let _ = try await fake.request("method1", params: ["a": 1])
        let _ = try await fake.request("method2", params: ["b": 2])
        
        #expect(fake.requestLog.count == 2)
        #expect(fake.requestLog[0].method == "method1")
        #expect(fake.requestLog[1].method == "method2")
        #expect(fake.didCallMethod("method1"))
        #expect(fake.didCallMethod("method2"))
        #expect(!fake.didCallMethod("method3"))
    }
    
    // MARK: - Legacy Event Handlers
    
    @Test func legacyEventHandlerRegistration() async throws {
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
    
    @Test func subscriptionHandlerRegistrationAndDelivery() async throws {
        let fake = FakeConnectionManager()
        
        var receivedPushes: [SubscriptionPush] = []
        fake.registerSubscriptionHandler(id: "sub-123") { push in
            receivedPushes.append(push)
        }
        
        #expect(fake.hasSubscriptionHandler(id: "sub-123"))
        #expect(fake.subscriptionHandlerCount == 1)
        
        let push = SubscriptionPush(
            subscriptionId: "sub-123",
            kind: .snapshot,
            seq: 0,
            snapshot: [["id": "1"]],
            delta: nil
        )
        
        fake.deliverSubscriptionPush(push)
        #expect(receivedPushes.count == 1)
        #expect(receivedPushes[0].subscriptionId == "sub-123")
        #expect(receivedPushes[0].seq == 0)
    }
    
    @Test func subscriptionPushOnlyReachesRegisteredHandler() async throws {
        let fake = FakeConnectionManager()
        
        var receivedA: [SubscriptionPush] = []
        var receivedB: [SubscriptionPush] = []
        
        fake.registerSubscriptionHandler(id: "sub-A") { push in
            receivedA.append(push)
        }
        fake.registerSubscriptionHandler(id: "sub-B") { push in
            receivedB.append(push)
        }
        
        let pushA = SubscriptionPush(subscriptionId: "sub-A", kind: .snapshot, seq: 0, snapshot: [], delta: nil)
        let pushB = SubscriptionPush(subscriptionId: "sub-B", kind: .snapshot, seq: 0, snapshot: [], delta: nil)
        
        fake.deliverSubscriptionPush(pushA)
        #expect(receivedA.count == 1)
        #expect(receivedB.count == 0)
        
        fake.deliverSubscriptionPush(pushB)
        #expect(receivedA.count == 1)
        #expect(receivedB.count == 1)
    }
}
