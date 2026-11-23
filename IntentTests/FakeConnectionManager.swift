import Combine
import Foundation
@testable import Intent
import Synchronization
import Testing

struct ConditionWaitFailure: Error, CustomStringConvertible {
    let description: String
}

private let kConditionPollIntervalMilliseconds = 5
private let kConditionPollInterval: Duration = .milliseconds(kConditionPollIntervalMilliseconds)

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

    func opening<T>(onCancellationOf body: () async throws -> T) async rethrows -> T {
        try await withTaskCancellationHandler(operation: body) { open() }
    }
}

nonisolated func suspendUntilCancelled() async {
    let gate = TestGate()
    await withTaskCancellationHandler {
        await gate.wait()
    } onCancel: {
        gate.open()
    }
}

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
        set {
            if newValue == .connected {
                currentPrincipal = currentPrincipal ?? lastConnectedPrincipal
            } else if let principal = currentPrincipal {
                lastConnectedPrincipal = principal
                currentPrincipal = nil
            }
            _connectionState.send(newValue)
        }
    }
    var lastConnectedPrincipal: ConnectionPrincipal?
    var startupState: DaemonStartupState?

    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> {
        _connectionState.eraseToAnyPublisher()
    }

    var currentPrincipal: ConnectionPrincipal? = .demoOwner
    var capabilities: ConnectionCapabilities = .unknown
    var reconnectStopReason: String?
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

    var connectLog: [ConnectionLogEntry] = []
    var connectError: Error?

    var updateCachedCredentialsLog: [ConnectionLogEntry] = []

    private(set) var disconnectCallCount = 0
    private(set) var refreshHostRoutesCallCount = 0
    private(set) var retryConnectionCallCount = 0

    func retryConnection() { retryConnectionCallCount += 1 }

    #if DEBUG
    func connectDemo(serveFixtures _: Bool) {
        globalSubscriptionState = .subscribed
        connectionState = .connected
    }
    #endif

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
        lastConnectedPrincipal = nil
    }

    // MARK: - Request/Response Mocking

    var responseMap: [String: Any] = [
        "client.hello": ["server": ["protocolVersion": ProtocolFixtures.currentProtocolVersion, "capabilities": [String: Int]()]],
        "principal.me": ["id": "test-owner", "isAdministrator": true]
    ]

    var responseQueueMap: [String: [Any]] = [:]

    var errorMap: [String: Error] = [:]

    var errorQueueMap: [String: [Error]] = [:]

    var requestLog: [RequestLogEntry] = []

    var pendingMethods: Set<String> = []
    var failsCancelledRequests = false
    private var pendingContinuations: [String: [(id: UUID, continuation: CheckedContinuation<Any, Error>)]] = [:]

    func resolvePending(_ method: String, with response: sending Any) {
        guard var queue = pendingContinuations[method], !queue.isEmpty else { return }
        let pending = queue.removeFirst()
        pendingContinuations[method] = queue
        pending.continuation.resume(returning: response)
    }

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

    func deliverEvent(method: String, params: Any) {
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

    var chatSnapshotMap: [String: [[String: Any]]] = [:]
    var chatSnapshotMetaMap: [String: [String: Any]] = [:]

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

    private(set) var unregisteredSubscriptionIds: [String] = []

    func unregisterSubscriptionHandler(id: String) {
        unregisteredSubscriptionIds.append(id)
        subscriptionHandlers.removeValue(forKey: id)
    }

    func deliverSubscriptionPush(_ push: SubscriptionPush) {
        if let handler = subscriptionHandlers[push.subscriptionId] {
            handler(push)
        }
    }

    // MARK: - Test Helpers

    func clearRequestLog() {
        requestLog.removeAll()
    }

    func paramsForMethod(_ method: String) -> [[String: Any]] {
        requestLog.filter { $0.method == method }.map { $0.params }
    }

    func pendingRequestCount(_ method: String) -> Int {
        pendingContinuations[method]?.count ?? 0
    }

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

    var eventHandlerIDs: Set<UUID> { Set(eventHandlers.keys) }

    var eventHandlerCount: Int {
        eventHandlers.count
    }
}

extension FakeConnectionManager {
    func hasSubscriptionHandler(id: String) -> Bool {
        subscriptionHandlers[id] != nil
    }

    var subscriptionHandlerCount: Int {
        subscriptionHandlers.count
    }

    func didCallMethod(_ method: String) -> Bool {
        requestLog.contains { $0.method == method }
    }
}

extension FakeConnectionManager {
    func simulateConnect() {
        connectionState = .connected
    }

    func simulateStoppedReconnection() {
        reconnectStopReason = "Reconnection stopped."
        simulateDisconnect()
    }

    func simulateDisconnect() {
        pairingAttemptID = nil
        admission = nil
        connectionState = .disconnected
    }
}
