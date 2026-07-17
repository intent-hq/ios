import Foundation
import Combine
@testable import Intent

/// Fake ConnectionManager for testing store subscribe lifecycle.
/// Allows tests to:
/// - Control connection state transitions
/// - Inject RPC responses (subscribe/unsubscribe)
/// - Inject events (subscription.push)
/// - Verify that stores call the correct methods
@MainActor
class FakeConnectionManager: ConnectionManagerProtocol {
    @Published var connectionState: ConnectionState = .disconnected
    var connectionStatePublisher: Published<ConnectionState>.Publisher { $connectionState }
    
    private var eventHandlers: [UUID: (String, Any) -> Void] = [:]
    
    // Test hooks
    var requestLog: [(method: String, params: [String: Any])] = []
    var requestResponses: [String: Any] = [:]  // method -> response
    var shouldThrowOnRequest: [String: Error] = [:]  // method -> error
    
    func request(_ method: String, params: [String: Any]) async throws -> Any {
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
    func onEvent(_ handler: @escaping (String, Any) -> Void) -> UUID {
        let id = UUID()
        eventHandlers[id] = handler
        return id
    }
    
    func removeEventHandler(id: UUID) {
        eventHandlers.removeValue(forKey: id)
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
    
    /// Inject a subscription.push event
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
        
        injectEvent(method: "subscription.push", params: params)
    }
    
    /// Reset test state
    func reset() {
        requestLog.removeAll()
        requestResponses.removeAll()
        shouldThrowOnRequest.removeAll()
        eventHandlers.removeAll()
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
