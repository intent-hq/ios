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
        // Required: the poll interval of this bounded condition wait, not a
        // fixed delay — it returns as soon as `condition` holds.
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
        // Required: this helper's contract is a timed observation window;
        // the sleep is its poll interval.
        try await Task.sleep(for: kConditionPollInterval)
    } while ContinuousClock.now < deadline
    if forbidden() {
        throw ConditionWaitFailure(
            description: "Unexpected \(description) (\(sourceLocation.fileName):\(sourceLocation.line))"
        )
    }
}

/// Lets the main queue run everything already queued on it — a
/// `.receive(on: DispatchQueue.main)` delivery, a resumed main-actor request,
/// a `Task` spawned by either — and then the work those jobs queue in turn,
/// for `rounds` generations. Ordering-based, not time-based: the main actor
/// runs on the main queue in FIFO order, so each enqueued block runs only
/// after every job queued before it. For assertions that work did NOT happen
/// after its trigger was delivered; positive waits must use `waitUntil`.
@MainActor
func drainMainQueue(rounds: Int = 10) async {
    for _ in 0 ..< rounds {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
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

    var currentPrincipal: ConnectionPrincipal? = .demoOwner
    var admission: ConnectionAdmission?
    var pairingAttemptID: UUID?

    func confirmedPrincipal() async throws -> ConnectionPrincipal {
        let hello = try await request("client.hello")
        let value = try await request("principal.me")
        let principal = try ConnectionPrincipal.parse(value, hello: hello)
        currentPrincipal = principal
        if let previous = admission {
            admission = ConnectionAdmission(id: previous.id, token: previous.token, fingerprint: previous.fingerprint, principal: principal)
        }
        return principal
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

    private let globalSubscriptionSubject = CurrentValueSubject<ConnectionManager.GlobalSubscriptionState, Never>(.subscribed)
    var globalSubscriptionState: ConnectionManager.GlobalSubscriptionState {
        get { globalSubscriptionSubject.value }
        set { globalSubscriptionSubject.send(newValue) }
    }
    var globalSubscriptionPublisher: AnyPublisher<ConnectionManager.GlobalSubscriptionState, Never> {
        globalSubscriptionSubject.eraseToAnyPublisher()
    }
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
    private(set) var retryConnectionCallCount = 0

    func retryConnection() { retryConnectionCallCount += 1 }

    func connectDemo(serveFixtures _: Bool) {
        globalSubscriptionState = .subscribed
        connectionState = .connected
    }

    func connect(
        hosts: [String],
        port: Int,
        token: String,
        certFingerprint: String?,
        tcAddress: String?
    ) throws {
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
        pairingAttemptID = PairingConnectionContext.attemptID
        admission = ConnectionAdmission(id: UUID(), token: token, fingerprint: certFingerprint, principal: currentPrincipal ?? .demoOwner)
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

    func refreshHostRoutes() {
        refreshHostRoutesCallCount += 1
    }

    func disconnect() {
        disconnectCallCount += 1
        simulateDisconnect()
    }

    // MARK: - Request/Response Mocking

    /// Map of method names to response values. If a method is not in this map, request() throws.
    var responseMap: [String: Any] = [
        "client.hello": ["server": ["protocolVersion": ProtocolFixtures.currentProtocolVersion, "capabilities": [String: Int]()]],
        "principal.me": ["id": "test-owner", "isAdministrator": true]
    ]

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

    /// Methods whose requests suspend until `resolvePending(_:with:)` supplies the
    /// payload (or `failPending(_:with:)` its error), so a test pins the exact
    /// outcome an in-flight request resolves with — e.g. a stale list captured
    /// before a state change — while later requests for the same method stay
    /// suspended.
    var pendingMethods: Set<String> = []
    /// Opt-in: throw `CancellationError` for requests made from a cancelled
    /// task, as `ConnectionManager.awaitResponse` does.
    var failsCancelledRequests = false
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
        // Like the real ConnectionManager, a request from an already-cancelled task fails at once.
        if failsCancelledRequests, Task.isCancelled { throw CancellationError() }
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
        pairingAttemptID = nil
        admission = nil
        connectionState = .disconnected
    }

    /// Clear all request logs.
    func clearRequestLog() {
        requestLog.removeAll()
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

    var eventHandlerIDs: Set<UUID> { Set(eventHandlers.keys) }

    /// Count of registered event handlers.
    var eventHandlerCount: Int {
        eventHandlers.count
    }

    /// Count of registered subscription handlers.
    var subscriptionHandlerCount: Int {
        subscriptionHandlers.count
    }
}

extension FakeConnectionManager {
    /// Check if a specific request method was called.
    func didCallMethod(_ method: String) -> Bool {
        requestLog.contains { $0.method == method }
    }
}
