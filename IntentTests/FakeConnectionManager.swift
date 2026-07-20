import Foundation
import Combine
@testable import Intent

/// FakeConnectionManager is a plain class (not a subclass of ConnectionManager) that conforms
/// to ConnectionManagerRouting for testing purposes. It provides full control over connection
/// state, request responses, and subscription push delivery.
@MainActor
class FakeConnectionManager: ConnectionManagerRouting {
    // MARK: - Published State
    
    private let _connectionState = CurrentValueSubject<ConnectionState, Never>(.disconnected)
    var connectionState: ConnectionState {
        get { _connectionState.value }
        set { _connectionState.send(newValue) }
    }
    
    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> {
        _connectionState.eraseToAnyPublisher()
    }
    
    // MARK: - Request/Response Mocking
    
    /// Map of method names to response values. If a method is not in this map, request() throws.
    var responseMap: [String: Any] = [:]
    
    /// Map of method names to errors. If a method is in this map, request() throws the error.
    var errorMap: [String: Error] = [:]
    
    /// Recorded request log: [(method, params, timestamp)]
    var requestLog: [(method: String, params: [String: Any], timestamp: Date)] = []

    /// Optional per-method artificial delay (nanoseconds) applied before responding,
    /// for tests that need to interleave work while a request is in flight.
    var delayMap: [String: UInt64] = [:]

    func request(_ method: String, params: [String: Any] = [:]) async throws -> Any {
        requestLog.append((method, params, Date()))

        if let delay = delayMap[method] {
            try await Task.sleep(nanoseconds: delay)
        }

        if let error = errorMap[method] {
            throw error
        }
        
        guard let response = responseMap[method] else {
            throw NSError(
                domain: "FakeConnectionManager",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "No response configured for method: \(method)"]
            )
        }
        
        return response
    }
    
    // MARK: - Legacy Event Handlers
    
    private var eventHandlers: [UUID: (String, Any) -> Void] = [:]
    
    @discardableResult
    func onEvent(_ handler: @escaping (String, Any) -> Void) -> UUID {
        let id = UUID()
        eventHandlers[id] = handler
        return id
    }
    
    func removeEventHandler(id: UUID) {
        eventHandlers.removeValue(forKey: id)
    }
    
    /// Deliver a legacy event to all registered handlers (does NOT deliver subscription.push).
    func deliverEvent(method: String, params: Any) {
        // Do not deliver subscription.push through legacy event handlers.
        // ConnectionManager routes subscription.push separately via registerSubscriptionHandler.
        if method == "subscription.push" {
            return
        }
        let handlers = Array(eventHandlers.values)
        for handler in handlers {
            handler(method, params)
        }
    }
    
    // MARK: - Subscription Push Routing
    
    private var subscriptionHandlers: [String: @MainActor (SubscriptionPush) -> Void] = [:]
    
    func registerSubscriptionHandler(id: String, handler: @escaping @MainActor (SubscriptionPush) -> Void) {
        subscriptionHandlers[id] = handler
    }
    
    func unregisterSubscriptionHandler(id: String) {
        subscriptionHandlers.removeValue(forKey: id)
    }
    
    /// Deliver a subscription.push to the handler registered for the given subscriptionId.
    /// If no handler is registered, this is a no-op (mimics ConnectionManager behavior).
    func deliverSubscriptionPush(_ push: SubscriptionPush) {
        if let handler = subscriptionHandlers[push.subscriptionId] {
            handler(push)
        }
    }
    
    // MARK: - Test Helpers
    
    /// Simulate a connection event (transition to .connected).
    func simulateConnect() {
        connectionState = .connected
    }
    
    /// Simulate a disconnection event (transition to .disconnected).
    func simulateDisconnect() {
        connectionState = .disconnected
    }
    
    /// Clear all request logs.
    func clearRequestLog() {
        requestLog.removeAll()
    }
    
    /// Check if a specific request method was called.
    func didCallMethod(_ method: String) -> Bool {
        return requestLog.contains { $0.method == method }
    }
    
    /// Get all parameters for calls to a specific method.
    func paramsForMethod(_ method: String) -> [[String: Any]] {
        return requestLog.filter { $0.method == method }.map { $0.params }
    }
    
    /// Check if a handler is registered for a given subscriptionId.
    func hasSubscriptionHandler(id: String) -> Bool {
        return subscriptionHandlers[id] != nil
    }
    
    /// Count of registered event handlers.
    var eventHandlerCount: Int {
        return eventHandlers.count
    }
    
    /// Count of registered subscription handlers.
    var subscriptionHandlerCount: Int {
        return subscriptionHandlers.count
    }
}
