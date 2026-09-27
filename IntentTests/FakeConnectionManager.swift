// swiftlint:disable file_length
import Combine
import Foundation
@testable import Intent
import Synchronization
import Testing

/// Thrown by `waitUntil` / `expectNever` so a missed or forbidden state
/// transition aborts the test instead of letting it continue against a fake
/// that never reached the awaited state (e.g. `resolvePending` on nothing).
struct ConditionWaitFailure: Error, CustomStringConvertible {
    let description: String
}

/// Poll cadence shared by the bounded condition waits below.
private let kConditionPollIntervalMilliseconds = 5
private let kConditionPollInterval: Duration = .milliseconds(kConditionPollIntervalMilliseconds)

/// Bounded poll until `condition` holds. Throws `ConditionWaitFailure` naming
/// the call site on timeout. Use this instead of a fixed `Task.sleep` after
/// spawning store work (ios#261).
@MainActor
func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(2),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return }
        try await Task.sleep(for: kConditionPollInterval)
    }
    if condition() { return }
    throw ConditionWaitFailure(
        description: "Timed out waiting for \(description) (\(sourceLocation.fileName):\(sourceLocation.line))"
    )
}

/// Bounded negative observation window: polls `forbidden` for `window` and
/// throws `ConditionWaitFailure` the first time it holds. For assertions that
/// work must NOT have been spawned — positive ones must use `waitUntil`. The
/// window is the same order as the sleeps it replaces, but a transient
/// occurrence inside it now fails instead of slipping past a single check.
@MainActor
func expectNever(
    _ description: String,
    within window: Duration = .milliseconds(100),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ forbidden: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + window
    repeat {
        if forbidden() {
            throw ConditionWaitFailure(
                description: "Unexpected \(description) (\(sourceLocation.fileName):\(sourceLocation.line))"
            )
        }
        try await Task.sleep(for: kConditionPollInterval)
    } while ContinuousClock.now < deadline
    if forbidden() {
        throw ConditionWaitFailure(
            description: "Unexpected \(description) (\(sourceLocation.fileName):\(sourceLocation.line))"
        )
    }
}

/// One-shot latch for scripting the order of racing fakes: `wait()` suspends
/// until `open()` (returning immediately once open) and ignores cancellation,
/// so a fake that must outlive its cancellation holds its lane until the test
/// releases it — instead of guessing a `Task.sleep` long enough for the other
/// candidate to win (ios#261).
nonisolated final class TestGate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            let waiters = state.waiters
            state.waiters = []
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyOpen = state.withLock { state in
                if state.isOpen { return true }
                state.waiters.append(continuation)
                return false
            }
            if alreadyOpen { continuation.resume() }
        }
    }

    /// Runs `body`, opening the gate if the CALLING task is cancelled — the
    /// test-level escape hatch for a `.timeLimit` test whose system under test
    /// regressed into awaiting the gated fake: Swift Testing only cancels the
    /// test cooperatively, and `wait()` ignores cancellation, so without this
    /// such a regression would hang the runner instead of failing. Cancelling
    /// a candidate task that is merely awaiting `wait()` does not open the gate.
    func opening<T>(onCancellationOf body: () async throws -> T) async rethrows -> T {
        try await withTaskCancellationHandler(operation: body) { open() }
    }
}

/// Suspends until the current task is cancelled. Replaces a long `Task.sleep`
/// whose only job was to be cut short by cancellation (a raced loser that is
/// released once the winner settles).
nonisolated func suspendUntilCancelled() async {
    let gate = TestGate()
    await withTaskCancellationHandler {
        await gate.wait()
    } onCancel: {
        gate.open()
    }
}

/// FakeConnectionManager is a plain class (not a subclass of ConnectionManager) that conforms
/// to SessionConnectionManaging for testing purposes. It provides full control over connection
/// state, request responses, and subscription push delivery.
@MainActor
class FakeConnectionManager: SessionConnectionManaging {
    struct ConnectionLogEntry {
        let hosts: [String]
        let port: Int
        let token: String
        let certFingerprint: String?
        let tcAddress: String?
    }

    struct RequestLogEntry {
        let method: String
        let params: [String: Any]
        let timestamp: Date
    }

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
    var browserProxyFactory: (@MainActor () async throws -> any BrowserProxySession)?

    func makeBrowserProxy() async throws -> any BrowserProxySession {
        guard let browserProxyFactory else { throw BrowserTunnelError.unavailable }
        return try await browserProxyFactory()
    }

    var globalSubscriptionState: ConnectionManager.GlobalSubscriptionState = .idle
    private(set) var retryGlobalSubscriptionCallCount = 0

    func retryGlobalSubscription() {
        retryGlobalSubscriptionCallCount += 1
        globalSubscriptionState = .subscribing(attempt: 1)
    }

    /// Recorded `connect` calls, and the error to throw instead of connecting.
    var connectLog: [ConnectionLogEntry] = []
    var connectError: Error?

    /// Recorded `updateCachedCredentials` calls.
    var updateCachedCredentialsLog: [ConnectionLogEntry] = []

    private(set) var disconnectCallCount = 0
    private(set) var refreshHostRoutesCallCount = 0

    func connect(
        hosts: [String],
        port: Int,
        token: String,
        certFingerprint: String?,
        tcAddress: String?
    ) async throws {
        connectLog.append(
            ConnectionLogEntry(
                hosts: hosts,
                port: port,
                token: token,
                certFingerprint: certFingerprint,
                tcAddress: tcAddress
            )
        )
        if let connectError { throw connectError }
        connectionState = .connected
    }

    func updateCachedCredentials(
        hosts: [String],
        port: Int,
        token: String,
        certFingerprint: String?,
        tcAddress: String?
    ) {
        updateCachedCredentialsLog.append(
            ConnectionLogEntry(
                hosts: hosts,
                port: port,
                token: token,
                certFingerprint: certFingerprint,
                tcAddress: tcAddress
            )
        )
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
    var requestLog: [RequestLogEntry] = []

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

    /// Fail the oldest suspended request for `method` with `error`.
    func failPending(_ method: String, with error: Error) {
        guard var queue = pendingContinuations[method], !queue.isEmpty else { return }
        let pending = queue.removeFirst()
        pendingContinuations[method] = queue
        pending.continuation.resume(throwing: error)
    }

    func request(
        _ method: String,
        params: [String: Any] = [:],
        timeout _: TimeInterval = ConnectionManager.defaultRequestTimeout
    ) async throws -> Any {
        requestLog.append(RequestLogEntry(method: method, params: params, timestamp: Date()))

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

    /// Seq-0 conversation snapshot rows (and optional `snapshotMeta`) pushed
    /// to a handler the moment it registers for that subscriptionId — the
    /// fake's stand-in for the snapshot a live `chat.subscribe` owes after
    /// its ack. Persistent like `responseMap`: every registration for the id
    /// receives it. See `stubChatSnapshot`.
    var chatSnapshotMap: [String: [[String: Any]]] = [:]
    var chatSnapshotMetaMap: [String: [String: Any]] = [:]

    /// Stubs `chat.subscribe` to ack with `subscriptionId` and push `messages`
    /// as its seq-0 snapshot as soon as the store registers its handler.
    func stubChatSnapshot(
        subscriptionId: String = "sub-1",
        messages: [[String: Any]] = [],
        meta: [String: Any] = [:]
    ) {
        responseMap["chat.subscribe"] = ["subscriptionId": subscriptionId]
        chatSnapshotMap[subscriptionId] = messages
        if meta.isEmpty {
            chatSnapshotMetaMap.removeValue(forKey: subscriptionId)
        } else {
            chatSnapshotMetaMap[subscriptionId] = meta
        }
    }

    func registerSubscriptionHandler(id: String, handler: @escaping @MainActor (SubscriptionPush) -> Void) {
        subscriptionHandlers[id] = handler
        if let rows = chatSnapshotMap[id] {
            handler(SubscriptionPush(
                subscriptionId: id,
                seq: 0,
                conversationSnapshot: rows,
                metadata: chatSnapshotMetaMap[id] ?? ["truncated": false, "totalMessages": rows.count]
            ))
        }
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
        requestLog.contains { $0.method == method }
    }

    /// Get all parameters for calls to a specific method.
    func paramsForMethod(_ method: String) -> [[String: Any]] {
        requestLog.filter { $0.method == method }.map { $0.params }
    }

    /// Number of requests for `method` currently suspended by `pendingMethods`.
    func pendingRequestCount(_ method: String) -> Int {
        pendingContinuations[method]?.count ?? 0
    }

    /// Bounded poll until at least `count` requests for `method` are suspended
    /// by `pendingMethods` — i.e. resolvable via `resolvePending` / `failPending`.
    func waitForPendingRequests(
        _ method: String,
        count: Int = 1,
        timeout: Duration = .seconds(2),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await waitUntil(
            "\(count) suspended request(s) to \(method)",
            timeout: timeout,
            sourceLocation: sourceLocation
        ) {
            pendingRequestCount(method) >= count
        }
    }

    /// Bounded poll until `method` has been requested at least `count` times.
    func waitForRequests(
        _ method: String,
        count: Int = 1,
        timeout: Duration = .seconds(2),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        try await waitUntil(
            "\(count) request(s) to \(method)",
            timeout: timeout,
            sourceLocation: sourceLocation
        ) {
            paramsForMethod(method).count >= count
        }
    }

    /// Check if a handler is registered for a given subscriptionId.
    func hasSubscriptionHandler(id: String) -> Bool {
        subscriptionHandlers[id] != nil
    }

    /// Count of registered event handlers.
    var eventHandlerCount: Int {
        eventHandlers.count
    }

    /// Count of registered subscription handlers.
    var subscriptionHandlerCount: Int {
        subscriptionHandlers.count
    }
}
