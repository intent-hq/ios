import Combine
import Foundation
import Observation
import os

@MainActor
@Observable class ConnectionManager: ConnectionManagerRouting {
    enum LocalIPsResult: Equatable {
        case unavailable
        case value([String])
    }

    private struct ReconnectParameters {
        let hosts: [String]
        let port: Int
        let token: String
        let certFingerprint: String?
        let tcAddress: String?
    }

    private struct ConnectTarget {
        let hosts: [String]
        let port: Int
        let token: String
        let certFingerprint: String?
        let tcAddress: String?
    }

    private struct ConnectAttemptContext {
        let generation: Int
        let attempt: Int
        let preservesLiveConnection: Bool
        let certMismatchesBeforeAttempt: [HostCertMismatch]
    }

    static let shared = ConnectionManager()

    var connectionState: ConnectionState = .disconnected {
        didSet { connectionStateSubject.send(connectionState) }
    }
    var certMismatchDetected = false {
        didSet { certMismatchSubject.send(certMismatchDetected) }
    }
    /// Every per-host certificate mismatch observed while racing hosts for the
    /// current target, keeping the latest fingerprint per host. Accumulates
    /// across reconnect attempts; cleared on a fresh `connect()` to a different
    /// target and on explicit `disconnect()`.
    var certMismatches: [HostCertMismatch] = [] {
        didSet { certMismatchesSubject.send(certMismatches) }
    }

    @ObservationIgnored private let connectionStateSubject = CurrentValueSubject<ConnectionState, Never>(.disconnected)
    @ObservationIgnored private let certMismatchSubject = CurrentValueSubject<Bool, Never>(false)
    @ObservationIgnored private let certMismatchesSubject = CurrentValueSubject<[HostCertMismatch], Never>([])
    @ObservationIgnored private let subscriptionRouter = ConnectionSubscriptionRouter()

    @ObservationIgnored private var socket: WebSocketConnection?
    @ObservationIgnored private var messagePumpTask: Task<Void, Never>?
    @ObservationIgnored var pendingRequests: [Int: CheckedContinuation<Any, Error>] = [:]
    @ObservationIgnored private var nextRequestId = 1
    @ObservationIgnored private var connectionGeneration: Int = 0
    /// Supersession order among overlapping `connect()` calls. The preserving
    /// path (pairing over a live connection) does not tear down — and so does
    /// not advance `connectionGeneration` — up front, so overlapping attempts
    /// share a generation; this counter ensures the NEWEST attempt wins the
    /// adoption race regardless of which one finishes first.
    @ObservationIgnored private var connectAttempt: Int = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var pingTimer: Timer?
    @ObservationIgnored private var lastPongReceived = Date()
    @ObservationIgnored private var lastSuccessfulConnectAt: CFAbsoluteTime?
    @ObservationIgnored private var lastReconnectAttempt = 0
    private static let pingInterval: TimeInterval = 15  // Send ping every 15s
    private static let pongTimeout: TimeInterval = 30   // Dead if no pong in 30s
    private static let stableConnectionThreshold: TimeInterval = 10
    nonisolated private static let millisecondsPerSecond: CFTimeInterval = 1000
    nonisolated private static let initialReconnectAttempt: Int = 1
    nonisolated private static let minimumBackedOffReconnectAttempt: Int = 2
    private static let webSocketErrorDomain = "WebSocket"
    private static let requestTimedOutErrorCode = -2
    private static let connectionClosedErrorCode = -3
    private static let notConnectedErrorCode = -4
    @ObservationIgnored private(set) var hosts: [String] = []
    @ObservationIgnored private var host: String?
    @ObservationIgnored private(set) var port: Int?
    @ObservationIgnored private(set) var token: String?
    @ObservationIgnored private(set) var certFingerprint: String?
    /// Tailcat tunnel address of the current target (nil when the daemon has
    /// no tunnel); adds the tunnel candidate to host racing when present.
    @ObservationIgnored private(set) var tcAddress: String?
    /// The tunnel session carrying the live socket (nil when a direct host
    /// won the race); closed on teardown.
    @ObservationIgnored private var activeTunnel: (any TunnelSession)?
    /// Injectable for tests; defaults to the real TailcatKit-backed dialer
    /// where the xcframework links (iOS), and to the always-failing stub on
    /// visionOS (no xros TailcatKit slice yet).
    #if canImport(TailcatKit)
    @ObservationIgnored var tunnelDialer: any TunnelDialing = TailcatTunnelDialer()
    #else
    @ObservationIgnored var tunnelDialer: any TunnelDialing = UnavailableTunnelDialer()
    #endif

    @ObservationIgnored var eventHandlers: [UUID: (String, Any) -> Void] = [:]

    /// The candidate label the tunnel route races under (also the host shown
    /// in its transport errors). Not a dialable name: the tunnel connects via
    /// a loopback forwarder.
    nonisolated static let tunnelCandidateLabel = "tailcat-tunnel"

    /// Internal (not private) so `BackendSessionRegistry` can construct one
    /// additional instance per pinned backend session; `.shared` remains the
    /// process-wide default used by the default session and existing code.
    init() {}
}

extension ConnectionManager {
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

    func connect(
        hosts: [String],
        port: Int,
        token: String,
        certFingerprint: String? = nil,
        tcAddress: String? = nil
    ) async throws {
        let target = ConnectTarget(
            hosts: hosts,
            port: port,
            token: token,
            certFingerprint: certFingerprint,
            tcAddress: tcAddress
        )
        let connectStart = CFAbsoluteTimeGetCurrent()
        let context = beginConnectAttempt(target)
        let raceStart = CFAbsoluteTimeGetCurrent()
        AppLog.connection.debug("[ConnectionManager] Connect: raceHosts starting at +\(Int((raceStart - connectStart) * Self.millisecondsPerSecond))ms")
        let raced: WonHostRace
        do {
            raced = try await raceHosts(target)
        } catch {
            restoreCertMismatchesAfterFailedConnect(context)
            throw error
        }
        let winner = raced.winner
        var lateMismatchGeneration = context.generation
        defer {
            recordLateCertMismatches(from: raced.drain, generation: lateMismatchGeneration)
        }
        let raceEnd = CFAbsoluteTimeGetCurrent()
        AppLog.connection.debug("[ConnectionManager] Connect: raceHosts completed in \(Int((raceEnd - raceStart) * Self.millisecondsPerSecond))ms (at +\(Int((raceEnd - connectStart) * Self.millisecondsPerSecond))ms)")
        AppLog.connection.debug("[ConnectionManager] Race won by \(winner.host), generation=\(context.generation)")
        do {
            try Task.checkCancellation()
        } catch {
            await winner.disconnect()
            throw error
        }
        guard connectionGeneration == context.generation, connectAttempt == context.attempt else {
            AppLog.connection.debug("[ConnectionManager] Superseded after race: generation current=\(connectionGeneration) mine=\(context.generation), attempt current=\(connectAttempt) mine=\(context.attempt)")
            await winner.disconnect()
            throw CancellationError()
        }
        lateMismatchGeneration = adoptConnectedWinner(
            winner,
            target: target,
            preservesLiveConnection: context.preservesLiveConnection,
            initialGeneration: context.generation
        )
        let setupEnd = CFAbsoluteTimeGetCurrent()
        AppLog.connection.debug("[ConnectionManager] Connect: socket setup completed in \(Int((setupEnd - raceEnd) * Self.millisecondsPerSecond))ms (at +\(Int((setupEnd - connectStart) * Self.millisecondsPerSecond))ms)")
        let totalElapsed = CFAbsoluteTimeGetCurrent() - connectStart
        AppLog.connection.debug("[ConnectionManager] Connect: total elapsed \(Int(totalElapsed * Self.millisecondsPerSecond))ms, connected to \(self.host ?? "?")")
    }

    private func beginConnectAttempt(_ target: ConnectTarget) -> ConnectAttemptContext {
        let previousMismatches = certMismatches
        resetCertMismatchesIfTargetChanged(
            hosts: target.hosts,
            port: target.port,
            certFingerprint: target.certFingerprint
        )
        let preservesLiveConnection: Bool
        switch connectionState {
        case .connected, .reconnecting:
            preservesLiveConnection = true
        case .connecting, .disconnected:
            preservesLiveConnection = false
            teardownConnection()
            cacheConnectTarget(target)
            connectionState = .connecting
        }
        let generation = connectionGeneration
        connectAttempt += 1
        return ConnectAttemptContext(
            generation: generation,
            attempt: connectAttempt,
            preservesLiveConnection: preservesLiveConnection,
            certMismatchesBeforeAttempt: previousMismatches
        )
    }

    private func raceHosts(_ target: ConnectTarget) async throws -> WonHostRace {
        try await raceHosts(
            target.hosts,
            port: target.port,
            token: target.token,
            certFingerprint: target.certFingerprint,
            tcAddress: target.tcAddress
        )
    }

    private func restoreCertMismatchesAfterFailedConnect(_ context: ConnectAttemptContext) {
        if context.preservesLiveConnection,
           connectionGeneration == context.generation,
           connectAttempt == context.attempt,
           certMismatches != context.certMismatchesBeforeAttempt {
            certMismatches = context.certMismatchesBeforeAttempt
        }
    }

    private func adoptConnectedWinner(
        _ winner: RacedConnection,
        target: ConnectTarget,
        preservesLiveConnection: Bool,
        initialGeneration: Int
    ) -> Int {
        var lateMismatchGeneration = initialGeneration
        if preservesLiveConnection {
            teardownConnection()
            lateMismatchGeneration = connectionGeneration
            cacheConnectTarget(target)
        }
        socket = winner.socket
        activeTunnel = winner.tunnel
        host = winner.host
        configureSocketMessagePump()
        connectionState = .connected
        lastSuccessfulConnectAt = CFAbsoluteTimeGetCurrent()
        lastReconnectAttempt = 0
        subscribeToAllEvents()
        startPingTimer()
        scheduleHostRoutesRefresh()
        return lateMismatchGeneration
    }

    private func cacheConnectTarget(_ target: ConnectTarget) {
        hosts = target.hosts
        port = target.port
        token = target.token
        certFingerprint = target.certFingerprint
        tcAddress = target.tcAddress
    }

    /// Adopt registry-merged fields for the ACTIVE connection (called when a
    /// synced-registry merge rewrote its stored record): refreshes the cached
    /// hosts/port/token/fingerprint that reconnect racing and ping recovery
    /// read, so they use the rotated token and current routes instead of the
    /// stale cache. The live socket is kept — the daemon checks the token at
    /// the WebSocket upgrade only, so an established connection stays valid.
    func updateCachedCredentials(
        hosts: [String],
        port: Int,
        token: String,
        certFingerprint: String?,
        tcAddress: String?
    ) {
        self.hosts = hosts
        self.port = port
        self.token = token
        self.certFingerprint = certFingerprint
        self.tcAddress = tcAddress
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
        let oldTunnel = activeTunnel
        activeTunnel = nil
        messagePumpTask?.cancel()
        messagePumpTask = nil
        Task {
            await oldSocket?.disconnect()
            await oldTunnel?.close()
        }
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
        hosts: [String],
        port: Int,
        certFingerprint: String?
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
    func request(
        _ method: String,
        params: [String: Any] = [:],
        timeout: TimeInterval = ConnectionManager.defaultRequestTimeout
    ) async throws -> Any {
        if DemoMode.isEnabled {
            return DemoFixtures.response(for: method, params: params)
        }
        guard let currentSocket = socket else {
            throw NSError(
                domain: Self.webSocketErrorDomain,
                code: Self.notConnectedErrorCode,
                userInfo: [NSLocalizedDescriptionKey: "Not connected"]
            )
        }

        let id = nextRequestId
        nextRequestId += 1

        var rpcDict: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if !params.isEmpty {
            rpcDict["params"] = params
        }
        let data = try JSONSerialization.data(withJSONObject: rpcDict)
        guard let requestText = String(data: data, encoding: .utf8) else {
            throw WebSocketTransportError.failed(
                host: currentSocket.host,
                message: "JSON-RPC request was not valid UTF-8"
            )
        }

        return try await awaitResponse(id: id, timeout: timeout) { [weak self] in
            AppLog.connection.debug("[ConnectionManager] Writing request id=\(id) method=\(method), socket=\(self?.socket != nil ? "exists" : "nil")")
            return Task { [weak self] in
                do {
                    try await currentSocket.send(requestText)
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
    func awaitResponse(
        id: Int,
        timeout: TimeInterval,
        write: @escaping @MainActor () -> Task<Void, Never>?
    ) async throws -> Any {
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0, timeout)))
            guard !Task.isCancelled else { return }
            if let continuation = self?.pendingRequests.removeValue(forKey: id) {
                continuation.resume(throwing: NSError(
                    domain: Self.webSocketErrorDomain,
                    code: Self.requestTimedOutErrorCode,
                    userInfo: [NSLocalizedDescriptionKey: "Request timed out"]
                ))
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
        guard connectionState == .connected, let token, let port else { return }
        let myGeneration = connectionGeneration

        // Refresh the stored display name first: it must run even when the
        // localIps flow below bails out (older daemon, transport hiccup).
        await refreshStoredDisplayName(token: token, port: port)

        guard let result = try? await request("system.status") else {
            AppLog.connection.debug("[ConnectionManager] Host route refresh: system.status failed (skipping)")
            return
        }

        // A newer connect() may have superseded us while the RPC was in flight.
        guard connectionGeneration == myGeneration else { return }

        // Adopt a reported tunnel address (additive: an absent field — older
        // daemon or tunnel down — keeps the known address rather than
        // clearing it, matching the never-drop host merge semantics).
        let reportedTc = Self.tcAddress(fromSystemStatus: result)
        if let reportedTc, reportedTc != tcAddress {
            AppLog.connection.debug("[ConnectionManager] Host route refresh: tcAddress updated")
            tcAddress = reportedTc
        }

        // The active connection, verified against the live token + port
        // (same record-matching rules as the host persistence below).
        if let reportedTc,
            let stored = PersistenceManager.shared.activeConnection(),
            stored.token == token, stored.server.port == port,
            stored.server.tcAddress != reportedTc {
            if !PersistenceManager.shared.updateConnectionTcAddress(
                id: stored.id,
                tcAddress: reportedTc
            ) {
                AppLog.connection.warning("[ConnectionManager] Could not persist refreshed tunnel route")
            }
        }

        guard case let .value(reported) = Self.localIps(fromSystemStatus: result), !reported.isEmpty else {
            AppLog.connection.debug("[ConnectionManager] Host route refresh: no localIps reported (skipping)")
            return
        }

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
                if !PersistenceManager.shared.updateConnectionHosts(
                    id: stored.id,
                    hosts: persistedHosts
                ) {
                    AppLog.connection.warning("[ConnectionManager] Could not persist refreshed host routes")
                }
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
            if !PersistenceManager.shared.updateConnectionDisplayName(
                id: stored.id,
                displayName: name
            ) {
                AppLog.connection.warning("[ConnectionManager] Could not persist refreshed display name")
            }
        }
    }

    /// Extracts the `localIps` array from a `system.status` result. Returns unavailable
    /// when the field is absent (older daemon) or malformed.
    static func localIps(fromSystemStatus result: Any) -> LocalIPsResult {
        guard let status = result as? [String: Any],
              let ips = status["localIps"] as? [String] else { return .unavailable }
        return .value(ips)
    }

    /// Extracts the `tcAddress` field from a `system.status` result. Returns
    /// nil when absent (older daemon, tunnel not running), malformed, or
    /// blank.
    static func tcAddress(fromSystemStatus result: Any) -> String? {
        guard let status = result as? [String: Any],
              let raw = status["tcAddress"] as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Merges daemon-reported IPs into the existing host list: existing hosts
    /// (originally paired/entered) keep their order and are never dropped;
    /// reported IPs not already present are appended, deduped.
    static func mergeHosts(existing: [String], reported: [String]) -> [String] {
        var merged = existing
        var seen = Set(existing)
        for ipAddress in reported {
            let trimmed = ipAddress.trimmingCharacters(in: .whitespacesAndNewlines)
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
              connectionLifetime < stableConnectionThreshold else { return initialReconnectAttempt }
        return max(previousAttempt + initialReconnectAttempt, minimumBackedOffReconnectAttempt)
    }

    // MARK: - Private

    /// A won race: the winner plus the background drain of the candidates
    /// still in flight (`HostRaceOutcome.drain`). The drain is handed to the
    /// caller because only it knows which connection generation the drain's
    /// late mismatches belong to (see `recordLateCertMismatches`).
    private typealias WonHostRace = (
        winner: RacedConnection,
        drain: Task<[HostCertMismatch], Never>?
    )

    private func raceHosts(
        _ hosts: [String],
        port: Int,
        token: String,
        certFingerprint: String?,
        tcAddress: String? = nil
    ) async throws -> WonHostRace {
        let myGeneration = connectionGeneration
        var candidates = hosts
        if tcAddress != nil {
            candidates.append(Self.tunnelCandidateLabel)
        }
        let dialer = tunnelDialer
        let outcome = await Self.raceCandidates(candidates) { [certFingerprint, token, tcAddress] candidate in
            let candidateStart = CFAbsoluteTimeGetCurrent()
            if candidate == Self.tunnelCandidateLabel, let tcAddress {
                AppLog.connection.debug("[ConnectionManager] Racing tailcat tunnel")
                let connection = try await Self.connectViaTunnel(
                    dialer: dialer,
                    tcAddress: tcAddress,
                    remotePort: port,
                    token: token,
                    certFingerprint: certFingerprint
                )
                let elapsed = Int((CFAbsoluteTimeGetCurrent() - candidateStart) * Self.millisecondsPerSecond)
                AppLog.connection.debug("[ConnectionManager] Tunnel connected in \(elapsed)ms")
                return connection
            }
            AppLog.connection.debug("[ConnectionManager] Racing host \(candidate):\(port)")
            let connection = try await WebSocketConnection.connect(
                host: candidate,
                port: port,
                token: token,
                certFingerprint: certFingerprint
            )
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - candidateStart) * Self.millisecondsPerSecond)
            AppLog.connection.debug("[ConnectionManager] Host \(candidate) connected in \(elapsed)ms")
            return RacedConnection(socket: connection, tunnel: nil, host: candidate)
        }
        // Surface every observed mismatch — even when a winner settled —
        // unless a newer connect()/disconnect() superseded this race.
        if connectionGeneration == myGeneration {
            recordCertMismatches(outcome.mismatches)
        }
        if let winner = outcome.winner {
            return (winner: winner, drain: outcome.drain)
        }
        recordLateCertMismatches(from: outcome.drain, generation: myGeneration)
        throw outcome.failure ?? WebSocketTransportError.failed(
            host: hosts.first ?? "unknown",
            message: "No reachable host found"
        )
    }

    /// Records the mismatches from candidates still in flight when a race
    /// settled, once the background drain finishes — unless
    /// `connectionGeneration` moved past `generation` by then (a newer
    /// connect() or disconnect() superseded the race).
    private func recordLateCertMismatches(
        from drain: Task<[HostCertMismatch], Never>?,
        generation: Int
    ) {
        guard let drain else { return }
        Task { [weak self] in
            let lateMismatches = await drain.value
            guard let self, connectionGeneration == generation else { return }
            recordCertMismatches(lateMismatches)
        }
    }

    /// One tunnel race candidate: establishes the tailcat tunnel (including
    /// its slow first-use warm-up), then completes the normal pinned WSS
    /// handshake through the tunnel's loopback forwarder. The tunnel is
    /// closed on any post-establishment failure so a lost race never leaks
    /// the session. Static + injected dialer for test visibility.
    nonisolated static func connectViaTunnel(
        dialer: any TunnelDialing,
        tcAddress: String,
        remotePort: Int,
        token: String,
        certFingerprint: String?
    ) async throws -> RacedConnection {
        let tunnel = try await dialer.open(tcAddress: tcAddress, remotePort: remotePort)
        do {
            try Task.checkCancellation()
            let socket = try await WebSocketConnection.connect(
                host: "127.0.0.1",
                port: tunnel.localPort,
                token: token,
                certFingerprint: certFingerprint
            )
            return RacedConnection(
                socket: socket,
                tunnel: tunnel,
                host: tunnelCandidateLabel
            )
        } catch {
            await tunnel.close()
            // Re-label loopback transport errors to the tunnel candidate so
            // failures surface against the route the user can recognize (and
            // a cert mismatch never collides with a real "127.0.0.1" host
            // entry).
            if let transportError = error as? WebSocketTransportError {
                switch transportError {
                case .certificateMismatch(_, let fingerprint):
                    throw WebSocketTransportError.certificateMismatch(
                        host: tunnelCandidateLabel,
                        fingerprint: fingerprint
                    )
                case .invalidURL:
                    throw WebSocketTransportError.invalidURL(host: tunnelCandidateLabel)
                case .timedOut:
                    throw WebSocketTransportError.timedOut(host: tunnelCandidateLabel)
                case .failed(_, let message):
                    throw WebSocketTransportError.failed(
                        host: tunnelCandidateLabel,
                        message: message
                    )
                case let .disconnected(_, code, reason):
                    throw WebSocketTransportError.disconnected(
                        host: tunnelCandidateLabel,
                        code: code,
                        reason: reason
                    )
                case .certificateMismatches:
                    throw transportError
                }
            }
            throw error
        }
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

    private func configureSocketMessagePump() {
        let currentSocket = socket
        messagePumpTask?.cancel()
        guard let currentSocket else { return }
        messagePumpTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await currentSocket.receive()
                    guard let self, socket === currentSocket else {
                        AppLog.connection.debug("[ConnectionManager] Ignoring message from stale socket")
                        return
                    }
                    switch message {
                    case .string(let text):
                        let preview = String(text.prefix(Constants.Connection.logPreviewCharacterLimit))
                        AppLog.connection.debug("[ConnectionManager] Received text: \(preview)...")
                        handleTextMessage(text)
                    case .data(let data):
                        AppLog.connection.debug("[ConnectionManager] Received binary: \(data.count) bytes")
                    @unknown default:
                        AppLog.connection.debug("[ConnectionManager] Received unknown WebSocket message")
                    }
                }
            } catch {
                guard !Task.isCancelled, let self, socket === currentSocket else { return }
                AppLog.connection.debug("[ConnectionManager] Socket error: \(error.localizedDescription)")
                handleDisconnection()
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
                        userInfo: userInfo
                    ))
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
        let oldTunnel = activeTunnel
        activeTunnel = nil
        messagePumpTask?.cancel()
        messagePumpTask = nil
        Task {
            await oldSocket?.disconnect()
            await oldTunnel?.close()
        }
        let connectionLifetime = lastSuccessfulConnectAt.map { disconnectTime - $0 }
        let startingAttempt = Self.reconnectStartingAttempt(
            connectionLifetime: connectionLifetime,
            previousAttempt: lastReconnectAttempt
        )
        lastSuccessfulConnectAt = nil
        if startingAttempt == Self.initialReconnectAttempt {
            lastReconnectAttempt = 0
        }
        connectionState = .reconnecting(attempt: startingAttempt)
        failAllPending(error: "Connection lost")
        subscriptionRouter.reset()
        startReconnection(disconnectTime: disconnectTime, startingAttempt: startingAttempt)
    }

    private func startReconnection(
        disconnectTime: CFAbsoluteTime? = nil,
        startingAttempt: Int = ConnectionManager.initialReconnectAttempt
    ) {
        reconnectTask?.cancel()
        let myGeneration = connectionGeneration
        let reconnectStart = disconnectTime ?? CFAbsoluteTimeGetCurrent()
        reconnectTask = Task { [weak self] in
            var attempt = startingAttempt
            while !Task.isCancelled {
                guard await Self.waitBeforeReconnectAttempt(attempt), let self else { return }
                let shouldStop = await performReconnectAttempt(
                    attempt: attempt,
                    generation: myGeneration,
                    reconnectStart: reconnectStart
                )
                if shouldStop { return }
                attempt += 1
            }
        }
    }

    nonisolated private static func waitBeforeReconnectAttempt(_ attempt: Int) async -> Bool {
        guard attempt > initialReconnectAttempt else { return !Task.isCancelled }
        let delay = await min(
            Double(1 << min(
                attempt - minimumBackedOffReconnectAttempt,
                Constants.Connection.reconnectBackoffExponentCap
            )),
            Constants.Connection.reconnectBackoffMaximum
        )
        try? await Task.sleep(for: .seconds(delay))
        return !Task.isCancelled
    }

    private func performReconnectAttempt(
        attempt: Int,
        generation: Int,
        reconnectStart: CFAbsoluteTime
    ) async -> Bool {
        let attemptStart = CFAbsoluteTimeGetCurrent()
        AppLog.connection.debug("[ConnectionManager] Reconnect attempt \(attempt) starting at +\(Int((attemptStart - reconnectStart) * Self.millisecondsPerSecond))ms")
        guard !Task.isCancelled, connectionGeneration == generation else { return true }
        connectionState = .reconnecting(attempt: attempt)
        let parameters = ReconnectParameters(
            hosts: hosts,
            port: port ?? 0,
            token: token ?? "",
            certFingerprint: certFingerprint,
            tcAddress: tcAddress
        )
        do {
            return try await connectReconnectCandidate(
                parameters,
                attempt: attempt,
                generation: generation,
                reconnectStart: reconnectStart
            )
        } catch {
            return handleReconnectFailure(error, attempt: attempt, generation: generation)
        }
    }

    private func connectReconnectCandidate(
        _ parameters: ReconnectParameters,
        attempt: Int,
        generation: Int,
        reconnectStart: CFAbsoluteTime
    ) async throws -> Bool {
        let raceStart = CFAbsoluteTimeGetCurrent()
        AppLog.connection.debug("[ConnectionManager] raceHosts starting at +\(Int((raceStart - reconnectStart) * Self.millisecondsPerSecond))ms")
        let raced = try await raceHosts(
            parameters.hosts,
            port: parameters.port,
            token: parameters.token,
            certFingerprint: parameters.certFingerprint,
            tcAddress: parameters.tcAddress
        )
        let raceEnd = CFAbsoluteTimeGetCurrent()
        AppLog.connection.debug("[ConnectionManager] raceHosts completed in \(Int((raceEnd - raceStart) * Self.millisecondsPerSecond))ms")
        let winner = raced.winner
        recordLateCertMismatches(from: raced.drain, generation: generation)
        guard !Task.isCancelled, adoptReconnectWinner(winner, attempt: attempt, generation: generation) else {
            await winner.disconnect()
            return true
        }
        let elapsed = (CFAbsoluteTimeGetCurrent() - reconnectStart) * Self.millisecondsPerSecond
        AppLog.connection.debug("[ConnectionManager] Reconnect complete in \(Int(elapsed))ms")
        return true
    }

    private func adoptReconnectWinner(
        _ winner: RacedConnection,
        attempt: Int,
        generation: Int
    ) -> Bool {
        guard !Task.isCancelled, connectionGeneration == generation else { return false }
        socket = winner.socket
        activeTunnel = winner.tunnel
        host = winner.host
        configureSocketMessagePump()
        connectionState = .connected
        lastSuccessfulConnectAt = CFAbsoluteTimeGetCurrent()
        lastReconnectAttempt = attempt
        subscribeToAllEvents()
        startPingTimer()
        scheduleHostRoutesRefresh()
        return true
    }

    private func handleReconnectFailure(_ error: Error, attempt: Int, generation: Int) -> Bool {
        if let transportError = error as? WebSocketTransportError,
           transportError.isCertificateMismatch {
            guard !Task.isCancelled, connectionGeneration == generation else { return true }
            AppLog.connection.debug("[ConnectionManager] Certificate mismatch detected, stopping reconnection")
            certMismatchDetected = true
            connectionState = .disconnected
            return true
        }
        AppLog.connection.debug("[ConnectionManager] Reconnect attempt \(attempt) failed: \(error.localizedDescription)")
        return false
    }

    private func subscribeToAllEvents() {
        Task {
            do {
                _ = try await self.request("events.subscribe", params: [
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
                domain: Self.webSocketErrorDomain,
                code: Self.connectionClosedErrorCode,
                userInfo: [NSLocalizedDescriptionKey: message]
            ))
        }
    }
}
