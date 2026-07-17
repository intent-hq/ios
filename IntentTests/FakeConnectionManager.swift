import Foundation
import Combine
@testable import Intent

/// Fake ConnectionManager for testing store subscribe lifecycle.
/// Subclasses ConnectionManager to provide test hooks while maintaining type compatibility.
/// Allows tests to:
/// - Control connection state transitions
/// - Inject RPC responses (subscribe/unsubscribe)
/// - Inject events (subscription.push) via router or legacy handlers
/// - Verify that stores call the correct methods
@MainActor
class FakeConnectionManager: ConnectionManager {
    // Test hooks
    var requestLog: [(method: String, params: [String: Any])] = []
    var requestResponses: [String: Any] = [:]  // method -> response
    var shouldThrowOnRequest: [String: Error] = [:]  // method -> error
    
    override func request(_ method: String, params: [String: Any]) async throws -> Any {
        requestLog.append((method, params))

        if let error = shouldThrowOnRequest[method] {
            throw error
        }

        if let response = requestResponses[method] {
            return response
        }

        // Default responses for common methods
        if method.hasSuffix(".subscribe") {
            let subId = "fake-sub-\(method)-\(UUID().uuidString.prefix(8))"
            return ["subscriptionId": subId]
        }

        if method.hasSuffix(".unsubscribe") {
            return ["ok": true]
        }

        return [:]
    }
    
    @discardableResult
    override func onEvent(_ handler: @escaping (String, Any) -> Void) -> UUID {
        // Call super to maintain any parent behavior, then track for tests
        let id = super.onEvent(handler)
        return id
    }

    override func removeEventHandler(id: UUID) {
        super.removeEventHandler(id: id)
    }

    /// Override router API from PR #15 to track subscriptions
    override func registerSubscriptionHandler(id: String, handler: @escaping @MainActor (SubscriptionPush) -> Void) {
        super.registerSubscriptionHandler(id: id, handler: handler)
    }

    /// Override router API from PR #15
    override func unregisterSubscriptionHandler(id: String) {
        super.unregisterSubscriptionHandler(id: id)
    }

    // Test helpers
    
    /// Simulate a connection event
    func simulateConnect() {
        connectionState = .connected
    }
    
    /// Simulate a disconnection
    func simulateDisconnect() {
        connectionState = .disconnected
    }
    
    /// Inject an event to all registered handlers
    func injectEvent(method: String, params: Any) {
        for handler in eventHandlers.values {
            handler(method, params)
        }
    }
    
    /// Inject a subscription.push event via the router (mimics PR #15's routing behavior).
    /// Constructs a JSON-RPC message and dispatches through the parent's dispatchMessage.
    func injectSubscriptionPush(
        subscriptionId: String,
        kind: SubscriptionPush.Kind,
        seq: Int,
        snapshot: [[String: Any]]? = nil,
        delta: SubscriptionPush.DeltaPayload? = nil
    ) {
        var params: [String: Any] = [
            "subscriptionId": subscriptionId,
            "kind": kind == .snapshot ? "snapshot" : "delta",
            "seq": seq
        ]

        if let snapshot = snapshot {
            params["snapshot"] = snapshot
        }

        if let delta = delta {
            params["delta"] = [
                "added": delta.added,
                "updated": delta.updated,
                "removedIds": delta.removedIds
            ]
        }

        // Build JSON-RPC message and dispatch through parent
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "subscription.push",
            "params": params
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: message),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            dispatchMessage(jsonString)
        }
    }
    
    /// Reset test state
    func reset() {
        requestLog.removeAll()
        requestResponses.removeAll()
        shouldThrowOnRequest.removeAll()
        connectionState = .disconnected
    }
    
    /// Verify a request was made
    func didRequest(method: String) -> Bool {
        requestLog.contains { $0.method == method }
    }
    
    /// Get parameters for last request of a given method
    func lastRequestParams(for method: String) -> [String: Any]? {
        requestLog.last { $0.method == method }?.params
    }
}
