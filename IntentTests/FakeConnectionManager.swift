import Foundation
import Combine
@testable import Intent

/// FakeConnectionManager is a plain class (not a subclass of ConnectionManager) that conforms
/// to SessionConnectionManaging for testing purposes. It provides full control over connection
/// state, request responses, and subscription push delivery.
@MainActor
class FakeConnectionManager: SessionConnectionManaging {
    // MARK: - Published State

    private let _connectionState = CurrentValueSubject<ConnectionState, Never>(.disconnected)
    var connectionState: ConnectionState {
        get { _connectionState.value }
        set { _connectionState.send(newValue) }
    }

    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> {
        _connectionState.eraseToAnyPublisher()
    }

    // MARK: - Session Connection Surface

    private let _certMismatchDetected = CurrentValueSubject<Bool, Never>(false)
    var certMismatchDetected: Bool {
        get { _certMismatchDetected.value }
        set { _certMismatchDetected.send(newValue) }
    }

    var certMismatchPublisher: AnyPublisher<Bool, Never> {
        _certMismatchDetected.eraseToAnyPublisher()
    }

    var certMismatches: [HostCertMismatch] = []

    var tunnelDialer: any TunnelDialing = UnavailableTunnelDialer()

    /// Recorded `connect` calls, and the error to throw instead of connecting.
    var connectLog: [(hosts: [String], port: Int, token: String,
                      certFingerprint: String?, tcAddress: String?)] = []
    var connectError: Error?

    /// Recorded `updateCachedCredentials` calls.
    var updateCachedCredentialsLog: [(hosts: [String], port: Int, token: String,
                                      certFingerprint: String?, tcAddress: String?)] = []

    private(set) var disconnectCallCount = 0
    private(set) var refreshHostRoutesCallCount = 0

    func connect(
        hosts: [String], port: Int, token: String, certFingerprint: String?,
        tcAddress: String?
    ) async throws {
        connectLog.append((hosts, port, token, certFingerprint, tcAddress))
        if let connectError { throw connectError }
        connectionState = .connected
    }

    func updateCachedCredentials(
        hosts: [String], port: Int, token: String, certFingerprint: String?,
        tcAddress: String?
    ) {
        updateCachedCredentialsLog.append((hosts, port, token, certFingerprint, tcAddress))
    }

    func refreshHostRoutes() async {
        refreshHostRoutesCallCount += 1
    }

    func disconnect() {
        disconnectCallCount += 1
        simulateDisconnect()
    }

    // MARK: - Request/Response Mocking
    
    /// Map of method names to response values. If a method is not in this map, request() throws.
    var responseMap: [String: Any] = [:]

    /// Per-method FIFO response queues. When non-empty for a method, each request()
    /// pops the next response — takes precedence over responseMap. Useful for
    /// pagination tests where consecutive calls return different pages.
    var responseQueueMap: [String: [Any]] = [:]

    /// Map of method names to errors. If a method is in this map, request() throws the error.
    var errorMap: [String: Error] = [:]

    /// Per-method FIFO error queues. When non-empty for a method, each request()
    /// pops and throws the next error — takes precedence over errorMap and the
    /// response maps. Useful for retry/fallback tests where only the first call
    /// should fail.
    var errorQueueMap: [String: [Error]] = [:]
    
    /// Recorded request log: [(method, params, timestamp)]
    var requestLog: [(method: String, params: [String: Any], timestamp: Date)] = []

    /// Optional per-method artificial delay (nanoseconds) applied before responding,
    /// for tests that need to interleave work while a request is in flight.
    var delayMap: [String: UInt64] = [:]

    /// Methods whose requests suspend until `resolvePending(_:with:)` supplies the
    /// payload. Unlike `delayMap` + `responseMap` (which reads the response only
    /// after the delay), this lets a test pin the exact payload an in-flight
    /// request resolves with — e.g. a stale list captured before a state change —
    /// while later requests for the same method stay suspended.
    var pendingMethods: Set<String> = []
    private var pendingContinuations: [String: [(id: UUID, continuation: CheckedContinuation<Any, Error>)]] = [:]

    /// Resolve the oldest suspended request for `method` with `response`.
    func resolvePending(_ method: String, with response: sending Any) {
        guard var queue = pendingContinuations[method], !queue.isEmpty else { return }
        let pending = queue.removeFirst()
        pendingContinuations[method] = queue
        pending.continuation.resume(returning: response)
    }

    func request(_ method: String, params: [String: Any] = [:],
                 timeout: TimeInterval = ConnectionManager.defaultRequestTimeout) async throws -> Any {
        requestLog.append((method, params, Date()))

        if pendingMethods.contains(method) {
            let requestId = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pendingContinuations[method, default: []].append((requestId, continuation))
                }
            } onCancel: {
                Task { @MainActor in
                    guard var queue = self.pendingContinuations[method],
                          let index = queue.firstIndex(where: { $0.id == requestId }) else { return }
                    let pending = queue.remove(at: index)
                    self.pendingContinuations[method] = queue
                    pending.continuation.resume(throwing: CancellationError())
                }
            }
        }

        if let delay = delayMap[method] {
            try await Task.sleep(nanoseconds: delay)
        }

        if var errorQueue = errorQueueMap[method], !errorQueue.isEmpty {
            let error = errorQueue.removeFirst()
            errorQueueMap[method] = errorQueue
            throw error
        }

        if let error = errorMap[method] {
            throw error
        }

        if var queue = responseQueueMap[method], !queue.isEmpty {
            let response = queue.removeFirst()
            responseQueueMap[method] = queue
            return response
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
