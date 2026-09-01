import Combine
import Foundation
import Observation

/// The minimal surface `ConnectionManager.raceCandidates` needs from a
/// connection candidate, letting tests race fakes instead of live sockets.
nonisolated protocol HostRacingConnection: Sendable {
    var host: String { get }
    func disconnect() async
}

extension WebSocketConnection: HostRacingConnection {}

/// The settled result of one `raceCandidates` run: the winner (if any), every
/// per-host certificate mismatch observed, and the failure to throw when no
/// candidate won.
nonisolated struct HostRaceOutcome<Connection: Sendable>: Sendable {
    let winner: Connection?
    let mismatches: [HostCertMismatch]
    let failure: (any Error)?
}

@MainActor
@Observable class ConnectionManager: ConnectionManagerRouting {
    static let shared = ConnectionManager()

    var connectionState: ConnectionState = .disconnected {
        didSet { connectionStateSubject?.send(connectionState) }
    }
    var certMismatchDetected = false {
        didSet { certMismatchSubject?.send(certMismatchDetected) }
    }
    /// Every per-host certificate mismatch observed while racing hosts for the
    /// current target, keeping the latest fingerprint per host. Accumulates
    /// across reconnect attempts; cleared on a fresh `connect()` to a different
    /// target and on explicit `disconnect()`.
    var certMismatches: [HostCertMismatch] = [] {
        didSet { certMismatchesSubject?.send(certMismatches) }
    }

    @ObservationIgnored private var connectionStateSubject: CurrentValueSubject<ConnectionState, Never>!
    @ObservationIgnored private var certMismatchSubject: CurrentValueSubject<Bool, Never>!
    @ObservationIgnored private var certMismatchesSubject: CurrentValueSubject<[HostCertMismatch], Never>!
    @ObservationIgnored private let subscriptionRouter = ConnectionSubscriptionRouter()

    @ObservationIgnored private var socket: WebSocketConnection?
    @ObservationIgnored private var messagePumpTask: Task<Void, Never>?
    @ObservationIgnored var pendingRequests: [Int: CheckedContinuation<Any, Error>] = [:]
    @ObservationIgnored private var nextRequestId = 1
    @ObservationIgnored private var connectionGeneration: Int = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var pingTimer: Timer?
    @ObservationIgnored private var lastPongReceived: Date = Date()
    @ObservationIgnored private var lastSuccessfulConnectAt: CFAbsoluteTime?
    @ObservationIgnored private var lastReconnectAttempt = 0
    private static let pingInterval: TimeInterval = 15  // Send ping every 15s
    private static let pongTimeout: TimeInterval = 30   // Dead if no pong in 30s
    private static let stableConnectionThreshold: TimeInterval = 10
    @ObservationIgnored private(set) var hosts: [String] = []
    @ObservationIgnored private var host: String?
    @ObservationIgnored private(set) var port: Int?
    @ObservationIgnored private(set) var token: String?
    @ObservationIgnored private(set) var certFingerprint: String?
    @ObservationIgnored var eventHandlers: [UUID: (String, Any) -> Void] = [:]

    private init() {
        connectionStateSubject = CurrentValueSubject(connectionState)
        certMismatchSubject = CurrentValueSubject(certMismatchDetected)
        certMismatchesSubject = CurrentValueSubject(certMismatches)
    }

    /// Combine compatibility for stores that depend on ConnectionManagerRouting.
    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> {
        connectionStateSubject.eraseToAnyPublisher()
    }

    /// Combine compatibility for AppCoordinator's certificate-mismatch routing.
    var certMismatchPublisher: AnyPublisher<Bool, Never> {
        certMismatchSubject.eraseToAnyPublisher()
    }

    /// Combine mirror of `certMismatches`, matching `certMismatchPublisher`.
    var certMismatchesPublisher: AnyPublisher<[HostCertMismatch], Never> {
        certMismatchesSubject.eraseToAnyPublisher()
    }

    // MARK: - Connection lifecycle

    func connect(hosts: [String], port: Int, token: String, certFingerprint: String? = nil) async throws {
        let connectStart = CFAbsoluteTimeGetCurrent()
        resetCertMismatchesIfTargetChanged(hosts: hosts, port: port, certFingerprint: certFingerprint)
        teardownConnection()
        let myGeneration = connectionGeneration
        self.hosts = hosts
        self.port = port
        self.token = token
        self.certFingerprint = certFingerprint
        connectionState = .connecting

        let raceStart = CFAbsoluteTimeGetCurrent()
        AppLog.connection.debug("[ConnectionManager] Connect: raceHosts starting at +\(Int((raceStart - connectStart) * 1000))ms")

        let winningSocket = try await raceHosts(hosts, port: port, token: token, certFingerprint: certFingerprint)

        let raceEnd = CFAbsoluteTimeGetCurrent()
        AppLog.connection.debug("[ConnectionManager] Connect: raceHosts completed in \(Int((raceEnd - raceStart) * 1000))ms (at +\(Int((raceEnd - connectStart) * 1000))ms)")
        AppLog.connection.debug("[ConnectionManager] Race won by \(winningSocket.host), generation=\(myGeneration)")

        do {
            try Task.checkCancellation()
        } catch {
            await winningSocket.disconnect()
            throw error
        }

        // Check if we've been superseded by a newer connect() call
        guard connectionGeneration == myGeneration else {
            AppLog.connection.debug("[ConnectionManager] Generation mismatch after race: current=\(connectionGeneration), mine=\(myGeneration)")
            await winningSocket.disconnect()
            throw CancellationError()
        }

        self.socket = winningSocket
        self.host = winningSocket.host
        configureSocketMessagePump()

        let setupEnd = CFAbsoluteTimeGetCurrent()
        AppLog.connection.debug("[ConnectionManager] Connect: socket setup completed in \(Int((setupEnd - raceEnd) * 1000))ms (at +\(Int((setupEnd - connectStart) * 1000))ms)")

        connectionState = .connected
        lastSuccessfulConnectAt = CFAbsoluteTimeGetCurrent()
        lastReconnectAttempt = 0
        subscribeToAllEvents()
        startPingTimer()
        scheduleHostRoutesRefresh()

        let totalElapsed = CFAbsoluteTimeGetCurrent() - connectStart
        AppLog.connection.debug("[ConnectionManager] Connect: total elapsed \(Int(totalElapsed * 1000))ms, connected to \(self.host ?? "?")")
    }

    /// Adopt registry-merged fields for the ACTIVE connection (called when a
    /// synced-registry merge rewrote its stored record): refreshes the cached
    /// hosts/port/token/fingerprint that reconnect racing and ping recovery
    /// read, so they use the rotated token and current routes instead of the
    /// stale cache. The live socket is kept — the daemon checks the token at
    /// the WebSocket upgrade only, so an established connection stays valid.
    func updateCachedCredentials(
        hosts: [String], port: Int, token: String, certFingerprint: String?
    ) {
        self.hosts = hosts
        self.port = port
        self.token = token
        self.certFingerprint = certFingerprint
    }

    func disconnect() {
        teardownConnection()
        if !certMismatches.isEmpty { certMismatches = [] }
    }

    /// Tears down the live connection without touching `certMismatches`:
    /// `connect()` to the same target must keep the accumulated mismatches,
    /// while an explicit `disconnect()` clears them.
    private func teardownConnection() {
        connectionGeneration += 1
        stopPingTimer()
        reconnectTask?.cancel()
        reconnectTask = nil
        lastSuccessfulConnectAt = nil
        lastReconnectAttempt = 0
        let oldSocket = socket
        socket = nil
        messagePumpTask?.cancel()
        messagePumpTask = nil
        Task { await oldSocket?.disconnect() }
        connectionState = .disconnected
        failAllPending(error: "Connection closed")
        subscriptionRouter.reset()
    }

    /// Drops accumulated mismatches when a fresh `connect()` targets a
    /// different backend than the cached one. When a pin is present, port +
    /// pin identify the daemon (host lists drift: `refreshHostRoutes()` merges
    /// daemon-reported IPs into `self.hosts`, so a later connect from the
    /// stored record would look different under exact host equality);
    /// pinless targets fall back to host overlap. Internal for test
    /// visibility.
    func resetCertMismatchesIfTargetChanged(
        hosts: [String], port: Int, certFingerprint: String?
    ) {
        let sameTarget = port == self.port
            && certFingerprint == self.certFingerprint
            && (certFingerprint != nil || !Set(hosts).isDisjoint(with: self.hosts))
        if !sameTarget, !certMismatches.isEmpty { certMismatches = [] }
    }

    // MARK: - Public API

    /// Default per-request RPC timeout. Individual calls may pass a longer
    /// `timeout` to `request(_:params:timeout:)` when the daemon operation is
    /// known to outlast this bound (e.g. `workspace.create`).
    static let defaultRequestTimeout: TimeInterval = 10

    /// Sends a JSON-RPC request and awaits its response.
    ///
    /// - Parameter timeout: Per-call timeout override in seconds (defaults to
    ///   `defaultRequestTimeout`). Long-running daemon operations must pass a
    ///   bound above the daemon's own budget so the daemon's structured result
    ///   (success or error) wins over a client-side transport timeout —
    ///   mirrors the per-call `timeoutMs` override in cloudlands-fe.
    func request(_ method: String, params: [String: Any] = [:],
                 timeout: TimeInterval = ConnectionManager.defaultRequestTimeout) async throws -> Any {
        if DemoMode.isEnabled {
            return DemoFixtures.response(for: method, params: params)
        }
        guard let currentSocket = socket else {
            throw NSError(domain: "WebSocket", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "Not connected"])
        }

        let id = nextRequestId
        nextRequestId += 1

        var rpcDict: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if !params.isEmpty {
            rpcDict["params"] = params
        }
        let data = try JSONSerialization.data(withJSONObject: rpcDict)
        let str = String(data: data, encoding: .utf8)!

        return try await awaitResponse(id: id, timeout: timeout) { [weak self] in
            AppLog.connection.debug("[ConnectionManager] Writing request id=\(id) method=\(method), socket=\(self?.socket != nil ? "exists" : "nil")")
            return Task { [weak self] in
                do {
                    try await currentSocket.send(str)
                    guard !Task.isCancelled else { return }
                    AppLog.connection.debug("[ConnectionManager] Write completed for request id=\(id) method=\(method)")
                } catch {
                    guard !Task.isCancelled else { return }
                    AppLog.connection.debug("[ConnectionManager] Write failed for request id=\(id) method=\(method): \(error.localizedDescription)")
                    guard self?.socket === currentSocket else { return }
                    self?.handleDisconnection()
                }
            }
        }
    }

    /// Registers a pending continuation for `id`, performs `write`, and races
    /// the response against `timeout`. Internal for test visibility (lets tests
    /// exercise the timeout race without a live socket).
    ///
    /// The continuation is resumed exactly once by whichever side wins:
    /// whoever removes the entry from `pendingRequests` (all on MainActor)
    /// owns the resume — a response via `handleTextMessage`, a disconnect via
    /// `failAllPending`, or the timeout task below. This guarantees a
    /// never-responding daemon still produces the timeout error instead of
    /// suspending forever (a suspended CheckedContinuation does not observe
    /// task cancellation).
    func awaitResponse(id: Int, timeout: TimeInterval,
                       write: @escaping @MainActor () -> Task<Void, Never>?) async throws -> Any {
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, timeout)))
            guard !Task.isCancelled else { return }
            if let continuation = self?.pendingRequests.removeValue(forKey: id) {
                continuation.resume(throwing: NSError(
                    domain: "WebSocket", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "Request timed out"]))
            }
        }
        var writeTask: Task<Void, Never>?
        defer {
            timeoutTask.cancel()
            writeTask?.cancel()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pendingRequests[id] = continuation
                writeTask = write()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if let continuation = self?.pendingRequests.removeValue(forKey: id) {
                    continuation.resume(throwing: CancellationError())
                }
            }
        }
    }
    func removeEventHandler(id: UUID) {
        eventHandlers.removeValue(forKey: id)
    }

    @discardableResult
    func onEvent(_ handler: @escaping (String, Any) -> Void) -> UUID {
        let id = UUID()
        eventHandlers[id] = handler
        return id
    }

    // MARK: - Subscription Push Routing

    func registerSubscriptionHandler(id: String, handler: @escaping @MainActor (SubscriptionPush) -> Void) {
        subscriptionRouter.register(id: id, handler: handler)
    }

    var subscriptionHandlerCount: Int {
        subscriptionRouter.handlerCount
    }

    func unregisterSubscriptionHandler(id: String) {
        subscriptionRouter.unregister(id: id)
    }

    func hasBufferedSubscriptionPush(for id: String) -> Bool {
        subscriptionRouter.hasBufferedPush(for: id)
    }

    func hasRecentlyUnregisteredSubscription(id: String) -> Bool {
        subscriptionRouter.hasRecentlyUnregisteredId(id)
    }

    var bufferedSubscriptionPushCount: Int {
        subscriptionRouter.bufferedPushCount
    }

    /// Internal entry point for testing message dispatch.
    @MainActor
    func dispatchMessage(_ text: String) {
        handleTextMessage(text)
    }

    // MARK: - Host route refresh

    /// Fire-and-forget wrapper around `refreshHostRoutes()`. Called from every
    /// successful connect path (initial connect and reconnect) so route refresh
    /// never delays the connection becoming usable.
    private func scheduleHostRoutesRefresh() {
        Task { await self.refreshHostRoutes() }
    }

    /// Shared post-connect hook: queries `system.status` for the daemon's
    /// `localIps` and merges them into the known host routes — both the
    /// in-memory list used by reconnect racing and the persisted
    /// `StoredConnection` record (the active connection, verified against the
    /// live token + port; updated by record id since `upsertConnection`
    /// matches by host set + port and would duplicate the record when the
    /// host set grows).
    ///
    /// Failures are non-fatal: older daemons without `localIps` and transport
    /// errors are skipped silently and the connection proceeds unchanged.
    func refreshHostRoutes() async {
        guard connectionState == .connected, let token = token, let port = port else { return }
        let myGeneration = connectionGeneration

        // Refresh the stored display name first: it must run even when the
        // localIps flow below bails out (older daemon, transport hiccup).
        await refreshStoredDisplayName(token: token, port: port)

        guard let result = try? await request("system.status") else {
            AppLog.connection.debug("[ConnectionManager] Host route refresh: system.status failed (skipping)")
            return
        }
        guard let reported = Self.localIps(fromSystemStatus: result), !reported.isEmpty else {
            AppLog.connection.debug("[ConnectionManager] Host route refresh: no localIps reported (skipping)")
            return
        }

        // A newer connect() may have superseded us while the RPC was in flight.
        guard connectionGeneration == myGeneration else { return }

        let merged = Self.mergeHosts(existing: hosts, reported: reported)
        if merged != hosts {
            AppLog.connection.debug("[ConnectionManager] Host route refresh: hosts \(hosts) -> \(merged)")
            hosts = merged
        }

        // Persist to the record we actually connected through: the active
        // connection. Token + port must match the live connection — during
        // initial pairing the active record is still the previous one (or
        // absent) until ConnectionPairing.finalize saves + activates the new
        // record and re-triggers this refresh. Matching by token + port alone
        // would be ambiguous: the same daemon can be saved as separate records
        // with different host sets at the same port.
        //
        // Merge against the STORED hosts, not just the in-memory merge: this
        // session may have connected with a narrower host list than the
        // record holds (e.g. a single-host manual re-pair while the record
        // also has a NAT hostname), and persisting the in-memory merge alone
        // would drop those hosts.
        if let stored = PersistenceManager.shared.activeConnection(),
            stored.token == token, stored.server.port == port {
            let persistedHosts = Self.mergeHosts(existing: stored.server.hosts, reported: merged)
            if stored.server.hosts != persistedHosts {
                PersistenceManager.shared.updateConnectionHosts(id: stored.id, hosts: persistedHosts)
            }
        }
    }

    /// Refreshes the active stored connection's display name from `host.status`
    /// (prettyHostname → hostname → keep existing), so connections saved before
    /// the daemon reported a pretty name heal on the next successful connect.
    /// Same record-matching rules as the host persistence in
    /// `refreshHostRoutes()`: the active connection, verified against the live
    /// token + port. Failures are non-fatal: older daemons and transport errors
    /// are skipped silently and the existing name is kept.
    private func refreshStoredDisplayName(token: String, port: Int) async {
        let myGeneration = connectionGeneration
        guard let result = try? await request("host.status"),
              let name = ConnectionPairing.displayName(fromHostStatus: result) else {
            return
        }

        // A newer connect() may have superseded us while the RPC was in flight.
        guard connectionGeneration == myGeneration else { return }

        if let stored = PersistenceManager.shared.activeConnection(),
            stored.token == token, stored.server.port == port,
            stored.displayName != name {
            AppLog.connection.debug("[ConnectionManager] Display name refresh: \(stored.displayName) -> \(name)")
            PersistenceManager.shared.updateConnectionDisplayName(id: stored.id, displayName: name)
        }
    }

    /// Extracts the `localIps` array from a `system.status` result. Returns nil
    /// when the field is absent (older daemon) or malformed.
    static func localIps(fromSystemStatus result: Any) -> [String]? {
        guard let status = result as? [String: Any],
              let ips = status["localIps"] as? [String] else { return nil }
        return ips
    }

    /// Merges daemon-reported IPs into the existing host list: existing hosts
    /// (originally paired/entered) keep their order and are never dropped;
    /// reported IPs not already present are appended, deduped.
    static func mergeHosts(existing: [String], reported: [String]) -> [String] {
        var merged = existing
        var seen = Set(existing)
        for ip in reported {
            let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            merged.append(trimmed)
            seen.insert(trimmed)
        }
        return merged
    }

    static func reconnectStartingAttempt(
        connectionLifetime: TimeInterval?,
        previousAttempt: Int
    ) -> Int {
        guard let connectionLifetime,
              connectionLifetime < stableConnectionThreshold else { return 1 }
        return max(previousAttempt + 1, 2)
    }

    // MARK: - Private

    private func raceHosts(
        _ hosts: [String],
        port: Int,
        token: String,
        certFingerprint: String?
    ) async throws -> WebSocketConnection {
        let myGeneration = connectionGeneration
        let outcome = await Self.raceCandidates(hosts) { [certFingerprint, token] host in
            let hostStart = CFAbsoluteTimeGetCurrent()
            AppLog.connection.debug("[ConnectionManager] Racing host \(host):\(port)")
            let connection = try await WebSocketConnection.connect(
                host: host,
                port: port,
                token: token,
                certFingerprint: certFingerprint)
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - hostStart) * 1000)
            AppLog.connection.debug("[ConnectionManager] Host \(host) connected in \(elapsed)ms")
            return connection
        }
        // Surface every observed mismatch — even when a winner settled —
        // unless a newer connect()/disconnect() superseded this race.
        if connectionGeneration == myGeneration {
            recordCertMismatches(outcome.mismatches)
        }
        if let winner = outcome.winner { return winner }
        throw outcome.failure ?? WebSocketTransportError.failed(
            host: hosts.first ?? "unknown", message: "No reachable host found")
    }

    /// Merges newly observed per-host mismatches into `certMismatches`,
    /// replacing a host's entry with its latest fingerprint. Internal for
    /// test visibility.
    func recordCertMismatches(_ observed: [HostCertMismatch]) {
        guard !observed.isEmpty else { return }
        var merged = certMismatches
        for mismatch in observed {
            if let index = merged.firstIndex(where: { $0.host == mismatch.host }) {
                merged[index] = mismatch
            } else {
                merged.append(mismatch)
            }
        }
        certMismatches = merged
    }

    /// Races one connect attempt per host and settles on the first success,
    /// collecting EVERY per-host certificate mismatch along the way (a loser's
    /// mismatch is not swallowed by the winner). When no candidate succeeds,
    /// `failure` prefers an aggregate certificate error over generic failures.
    /// Generic over the connection so tests can race fakes; internal for test
    /// visibility.
    nonisolated static func raceCandidates<Connection: HostRacingConnection>(
        _ hosts: [String],
        connect: @escaping @Sendable (String) async throws -> Connection
    ) async -> HostRaceOutcome<Connection> {
        await withThrowingTaskGroup(of: Connection.self) { group in
            for host in hosts {
                group.addTask { try await connect(host) }
            }

            var lastError: Error?
            var mismatches: [HostCertMismatch] = []
            var winner: Connection?
            var cancellationObserved = false
            while let result = await group.nextResult() {
                switch result {
                case .success(let connection):
                    if Task.isCancelled || cancellationObserved {
                        cancellationObserved = true
                        await connection.disconnect()
                        if let selectedWinner = winner {
                            await selectedWinner.disconnect()
                            winner = nil
                        }
                        group.cancelAll()
                        continue
                    }
                    if winner == nil {
                        winner = connection
                        group.cancelAll()
                    } else {
                        await connection.disconnect()
                    }
                case .failure(let error):
                    if Task.isCancelled {
                        cancellationObserved = true
                        group.cancelAll()
                    }
                    lastError = error
                    if let transportError = error as? WebSocketTransportError,
                       case .certificateMismatch(let host, let fingerprint) = transportError {
                        mismatches.append(HostCertMismatch(host: host, fingerprint: fingerprint))
                    }
                    AppLog.connection.debug("[ConnectionManager] Host racing: \(error.localizedDescription)")
                }
            }
            if cancellationObserved || Task.isCancelled {
                if let winner {
                    await winner.disconnect()
                }
                return HostRaceOutcome(
                    winner: nil, mismatches: mismatches, failure: CancellationError())
            }
            if let winner {
                return HostRaceOutcome(winner: winner, mismatches: mismatches, failure: nil)
            }
            if !mismatches.isEmpty {
                return HostRaceOutcome(
                    winner: nil, mismatches: mismatches,
                    failure: WebSocketTransportError.certificateMismatches(mismatches: mismatches))
            }
            return HostRaceOutcome(
                winner: nil, mismatches: mismatches,
                failure: lastError ?? WebSocketTransportError.failed(
                    host: hosts.first ?? "unknown", message: "No reachable host found"))
        }
    }

    private func configureSocketMessagePump() {
        let currentSocket = socket
        messagePumpTask?.cancel()
        guard let currentSocket else { return }
        messagePumpTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await currentSocket.receive()
                    guard let self, self.socket === currentSocket else {
                        AppLog.connection.debug("[ConnectionManager] Ignoring message from stale socket")
                        return
                    }
                    switch message {
                    case .string(let text):
                        let preview = String(text.prefix(100))
                        AppLog.connection.debug("[ConnectionManager] Received text: \(preview)...")
                        self.handleTextMessage(text)
                    case .data(let data):
                        AppLog.connection.debug("[ConnectionManager] Received binary: \(data.count) bytes")
                    @unknown default:
                        AppLog.connection.debug("[ConnectionManager] Received unknown WebSocket message")
                    }
                }
            } catch {
                guard !Task.isCancelled, let self, self.socket === currentSocket else { return }
                AppLog.connection.debug("[ConnectionManager] Socket error: \(error.localizedDescription)")
                self.handleDisconnection()
            }
        }
    }

    @MainActor
    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let id = json["id"] as? Int {
            if let continuation = pendingRequests.removeValue(forKey: id) {
                if let error = json["error"] as? [String: Any] {
                    let parsedCode = error["code"] as? Int
                    let code = parsedCode ?? -1
                    let hasCode = parsedCode != nil
                    let topMessage = error["message"] as? String ?? "Unknown error"
                    let errorData = error["data"] as? [String: Any]

                    // Extract error.data.message if present (daemon stashes real cause there)
                    var effectiveMessage = topMessage
                    if let dataMessage = errorData?["message"] as? String,
                       !dataMessage.isEmpty {
                        effectiveMessage = dataMessage
                    }

                    let description = hasCode ? "\(effectiveMessage) (\(code))" : effectiveMessage
                    var userInfo: [String: Any] = [NSLocalizedDescriptionKey: description]
                    // Preserve the error.data.code discriminator (PROTOCOL §3.3) so
                    // callers can distinguish "not-found" from "invalid-params".
                    if let dataCode = errorData?["code"] as? String {
                        userInfo[NSError.intentErrorDataCodeKey] = dataCode
                    }
                    continuation.resume(throwing: NSError(
                        domain: "WebSocket",
                        code: code,
                        userInfo: userInfo))
                } else {
                    continuation.resume(returning: json["result"] as Any)
                }
            }
        } else if let method = json["method"] as? String {
            let params = json["params"] as Any

            if subscriptionRouter.route(method: method, params: params) {
                return
            }

            // Broadcast other events to all legacy eventHandlers (subscription.push is NOT broadcast)
            for handler in eventHandlers.values {
                handler(method, params)
            }
        }
    }

    private func handleDisconnection() {
        let disconnectTime = CFAbsoluteTimeGetCurrent()
        AppLog.connection.debug("[ConnectionManager] handleDisconnection called, current state=\(connectionState)")
        guard connectionState != .disconnected else {
            AppLog.connection.debug("[ConnectionManager] Already disconnected, ignoring")
            return
        }
        stopPingTimer()
        let oldSocket = socket
        socket = nil
        messagePumpTask?.cancel()
        messagePumpTask = nil
        Task { await oldSocket?.disconnect() }
        let connectionLifetime = lastSuccessfulConnectAt.map { disconnectTime - $0 }
        let startingAttempt = Self.reconnectStartingAttempt(
            connectionLifetime: connectionLifetime,
            previousAttempt: lastReconnectAttempt)
        lastSuccessfulConnectAt = nil
        if startingAttempt == 1 {
            lastReconnectAttempt = 0
        }
        connectionState = .reconnecting(attempt: startingAttempt)
        failAllPending(error: "Connection lost")
        subscriptionRouter.reset()
        startReconnection(disconnectTime: disconnectTime, startingAttempt: startingAttempt)
    }

    private func startReconnection(
        disconnectTime: CFAbsoluteTime? = nil,
        startingAttempt: Int = 1
    ) {
        reconnectTask?.cancel()
        let myGeneration = connectionGeneration
        let reconnectStart = disconnectTime ?? CFAbsoluteTimeGetCurrent()
        reconnectTask = Task { [weak self] in
            var attempt = startingAttempt
            while !Task.isCancelled {
                if attempt > 1 {
                    let delay = min(Double(1 << min(attempt - 2, 5)), 30.0)
                    try? await Task.sleep(for: .seconds(delay))
                    if Task.isCancelled { break }
                }

                let attemptStart = CFAbsoluteTimeGetCurrent()
                AppLog.connection.debug("[ConnectionManager] Reconnect attempt \(attempt) starting at +\(Int((attemptStart - reconnectStart) * 1000))ms")

                // Check freshness before mutating observable state, then read the connection parameters.
                let parameters: ([String], Int, String, String?)?
                if !Task.isCancelled,
                   let self,
                   self.connectionGeneration == myGeneration {
                    self.connectionState = .reconnecting(attempt: attempt)
                    parameters = (self.hosts, self.port ?? 0, self.token ?? "", self.certFingerprint)
                } else {
                    parameters = nil
                }
                guard let (hostsToTry, currentPort, currentToken, currentCertFingerprint) = parameters else {
                    return
                }

                do {
                    let raceStart = CFAbsoluteTimeGetCurrent()
                    AppLog.connection.debug("[ConnectionManager] raceHosts starting at +\(Int((raceStart - reconnectStart) * 1000))ms")

                    let winningSocket = try await self?.raceHosts(hostsToTry, port: currentPort, token: currentToken, certFingerprint: currentCertFingerprint)

                    let raceEnd = CFAbsoluteTimeGetCurrent()
                    AppLog.connection.debug("[ConnectionManager] raceHosts completed in \(Int((raceEnd - raceStart) * 1000))ms")

                    guard let winningSocket = winningSocket else { continue }

                    do {
                        try Task.checkCancellation()
                    } catch {
                        await winningSocket.disconnect()
                        return
                    }

                    // Batch write: check generation + set up socket + transition to connected synchronously.
                    let genOk: Bool
                    if !Task.isCancelled,
                       let self,
                       self.connectionGeneration == myGeneration {
                        self.socket = winningSocket
                        self.host = winningSocket.host
                        self.configureSocketMessagePump()
                        self.connectionState = .connected
                        self.lastSuccessfulConnectAt = CFAbsoluteTimeGetCurrent()
                        self.lastReconnectAttempt = attempt
                        self.subscribeToAllEvents()
                        self.startPingTimer()
                        self.scheduleHostRoutesRefresh()
                        genOk = true
                    } else {
                        genOk = false
                    }
                    guard genOk else {
                        await winningSocket.disconnect()
                        return
                    }

                    let elapsed = (CFAbsoluteTimeGetCurrent() - reconnectStart) * 1000
                    AppLog.connection.debug("[ConnectionManager] Reconnect complete in \(Int(elapsed))ms")
                    return
                } catch {
                    if let transportError = error as? WebSocketTransportError,
                       transportError.isCertificateMismatch {
                        guard !Task.isCancelled,
                              self?.connectionGeneration == myGeneration else { return }
                        AppLog.connection.debug("[ConnectionManager] Certificate mismatch detected, stopping reconnection")
                        self?.certMismatchDetected = true
                        self?.connectionState = .disconnected
                        return
                    }
                    AppLog.connection.debug("[ConnectionManager] Reconnect attempt \(attempt) failed: \(error.localizedDescription)")
                }
                attempt += 1
            }
        }
    }

    private func subscribeToAllEvents() {
        Task {
            do {
                let _ = try await self.request("events.subscribe", params: [
                    "eventTypes": ["workspace:*", "note:*", "agent:*"],
                    "replaceGroup": "global"
                ])
                AppLog.connection.debug("[ConnectionManager] Subscribed to all events")
            } catch {
                AppLog.connection.error("[ConnectionManager] Failed to subscribe to events: \(error)")
            }
        }
    }

    // MARK: - Heartbeat

    private func startPingTimer() {
        stopPingTimer()
        lastPongReceived = Date()
        let timer = Timer(timeInterval: Self.pingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.sendPingAndCheckHealth()
            }
        }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func sendPingAndCheckHealth() async {
        guard connectionState == .connected, let currentSocket = socket else { return }

        // Check if we've timed out
        let timeSinceLastPong = Date().timeIntervalSince(lastPongReceived)
        if timeSinceLastPong > Self.pongTimeout {
            AppLog.connection.debug("[ConnectionManager] Ping timeout — no pong received in \(Int(timeSinceLastPong))s, triggering reconnection")
            stopPingTimer()
            handleDisconnection()
            return
        }

        do {
            try await currentSocket.sendPing()
            guard socket === currentSocket else { return }
            lastPongReceived = Date()
            AppLog.connection.debug("[ConnectionManager] Received pong")
        } catch {
            guard socket === currentSocket else { return }
            AppLog.connection.debug("[ConnectionManager] Ping failed: \(error.localizedDescription)")
            handleDisconnection()
        }
    }

    func failAllPending(error message: String) {
        let pending = pendingRequests
        pendingRequests.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: NSError(
                domain: "WebSocket", code: -3,
                userInfo: [NSLocalizedDescriptionKey: message]))
        }
    }
}
