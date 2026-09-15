import Combine
import Foundation
import Observation
import os

/// The minimal surface `ConnectionManager.raceCandidates` needs from a
/// connection candidate, letting tests race fakes instead of live sockets.
nonisolated protocol HostRacingConnection: Sendable {
    var host: String { get }
    func disconnect() async
}

extension WebSocketConnection: HostRacingConnection {}

/// One raced candidate's live result: the WebSocket plus the tailcat tunnel
/// session carrying it (nil for direct host candidates). `disconnect()` tears
/// down both, so loser cleanup in `raceCandidates` releases tunnel resources
/// when a direct host wins.
nonisolated struct RacedConnection: HostRacingConnection {
    let socket: WebSocketConnection
    let tunnel: (any TunnelSession)?
    /// The candidate label: the direct host, or
    /// `ConnectionManager.tunnelCandidateLabel` for the tunnel route.
    let host: String

    func disconnect() async {
        await socket.disconnect()
        await tunnel?.close()
    }
}

/// The settled result of one `raceCandidates` run: the winner (if any), every
/// per-host certificate mismatch observed before settling, and the failure to
/// throw when no candidate won.
nonisolated struct HostRaceOutcome<Connection: Sendable>: Sendable {
    let winner: Connection?
    let mismatches: [HostCertMismatch]
    let failure: (any Error)?
    /// The background task draining the candidates still in flight when the
    /// race settled: it disconnects every late success (a losing tunnel
    /// session is never leaked) and resolves to the certificate mismatches
    /// those candidates reported. `nil` when every candidate had already
    /// finished.
    let drain: Task<[HostCertMismatch], Never>?
}

/// A single-consumer mailbox for raced candidate results. `raceCandidates`
/// runs its candidates as unstructured tasks — a task group's body cannot
/// return before every child finishes, which is exactly the stall a slow
/// loser would cause — and awaits them here. Unlike `AsyncStream`, delivery
/// keeps working after the consuming task is cancelled, so cleanup can still
/// drain every candidate.
private nonisolated final class RaceMailbox<Connection: Sendable>: Sendable {
    private struct State: Sendable {
        var pending: [Result<Connection, any Error>] = []
        var waiter: CheckedContinuation<Result<Connection, any Error>, Never>?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func deliver(_ result: Result<Connection, any Error>) {
        let waiter = lock.withLock { state -> CheckedContinuation<Result<Connection, any Error>, Never>? in
            if let waiter = state.waiter {
                state.waiter = nil
                return waiter
            }
            state.pending.append(result)
            return nil
        }
        waiter?.resume(returning: result)
    }

    func next() async -> Result<Connection, any Error> {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { state -> Result<Connection, any Error>? in
                if state.pending.isEmpty {
                    state.waiter = continuation
                    return nil
                }
                return state.pending.removeFirst()
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

/// Carries an immutable Foundation JSON object (the output of
/// `JSONSerialization.jsonObject`) across isolation domains. `@unchecked
/// Sendable`: parsed JSON containers are never mutated after parse — the
/// message pump parses off MainActor and hands the value over for dispatch.
nonisolated struct InboundJSONValue: @unchecked Sendable {
    let value: Any
}

/// One inbound JSON-RPC frame, parsed off MainActor by
/// `ConnectionManager.parseInboundFrame(_:)` and dispatched on it.
nonisolated enum InboundFrame: Sendable {
    /// A successful response: `result` is the raw `result` field (may wrap a
    /// nil `Any` when absent), delivered to the pending continuation as-is.
    case response(id: Int, result: InboundJSONValue)
    /// An error response, already shaped into the `NSError` the pending
    /// continuation throws.
    case error(id: Int, error: NSError)
    /// A well-formed `subscription.push`, parsed (and, for the chat channel,
    /// pre-decoded into typed messages/blocks) off MainActor.
    case subscriptionPush(SubscriptionPush)
    /// Any other server notification (`events.event`, ...), plus a malformed
    /// `subscription.push` so the router can log and drop it.
    case notification(method: String, params: InboundJSONValue)

    /// The method or response id, for slow-frame logging.
    var label: String {
        switch self {
        case .response(let id, _), .error(let id, _): return "id=\(id)"
        case .subscriptionPush: return "method=subscription.push"
        case .notification(let method, _): return "method=\(method)"
        }
    }
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
    /// Supersession order among overlapping `connect()` calls. The preserving
    /// path (pairing over a live connection) does not tear down — and so does
    /// not advance `connectionGeneration` — up front, so overlapping attempts
    /// share a generation; this counter ensures the NEWEST attempt wins the
    /// adoption race regardless of which one finishes first.
    @ObservationIgnored private var connectAttempt: Int = 0
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
    init() {
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

    func connect(
        hosts: [String], port: Int, token: String, certFingerprint: String? = nil,
        tcAddress: String? = nil
    ) async throws {
        // Fail closed before touching any state or socket: a record without
        // a trusted pin would otherwise dial plain ws:// carrying the bearer
        // token (ios#251). Only the loopback test override may pass here;
        // per-host admission in WebSocketConnection.makeURL still applies.
        guard WebSocketConnection.trustedPin(certFingerprint) != nil
            || WebSocketConnection.allowsPlaintextLoopbackForTesting.withLock({ $0 })
        else {
            throw WebSocketTransportError.missingCertificatePin(host: hosts.first ?? "unknown")
        }
        let connectStart = CFAbsoluteTimeGetCurrent()
        // Snapshot before the reset: a preserving connect (below) that fails
        // must leave `certMismatches` exactly as the live connection had it —
        // neither cleared by this target-change reset nor polluted by
        // mismatches the failed pairing race recorded.
        let certMismatchesBeforeAttempt = certMismatches
        resetCertMismatchesIfTargetChanged(hosts: hosts, port: port, certFingerprint: certFingerprint)

        // A connect over an established or recovering connection (pairing a
        // new daemon via QR / manual token / intent:// link) must not tear
        // it down up front: if the new attempt fails, the existing
        // connection (or its reconnect loop) keeps serving instead of
        // stranding the app in .connecting on a dead socket (monorepo#4185).
        // The old connection is torn down only after the replacement socket
        // is established, below.
        let preservesLiveConnection: Bool
        switch connectionState {
        case .connected, .reconnecting:
            preservesLiveConnection = true
        case .connecting, .disconnected:
            preservesLiveConnection = false
            teardownConnection()
            self.hosts = hosts
            self.port = port
            self.token = token
            self.certFingerprint = certFingerprint
            self.tcAddress = tcAddress
            connectionState = .connecting
        }
        let myGeneration = connectionGeneration
        connectAttempt += 1
        let myAttempt = connectAttempt

        let raceStart = CFAbsoluteTimeGetCurrent()
        AppLog.connection.debug("[ConnectionManager] Connect: raceHosts starting at +\(Int((raceStart - connectStart) * 1000))ms")

        let raced: WonHostRace
        do {
            raced = try await raceHosts(
                hosts, port: port, token: token, certFingerprint: certFingerprint,
                tcAddress: tcAddress)
        } catch {
            // Failed preserving connect: the live connection keeps serving,
            // so restore its mismatch bookkeeping (unless a newer connect or
            // disconnect owns it now).
            if preservesLiveConnection,
                connectionGeneration == myGeneration, connectAttempt == myAttempt,
                certMismatches != certMismatchesBeforeAttempt {
                certMismatches = certMismatchesBeforeAttempt
            }
            throw error
        }
        let winner = raced.winner
        // The drain's late mismatches belong to this connect's generation.
        // The preserving path advances it below when it retires the old
        // connection — that is not supersession of this race — so the
        // generation to guard against is settled only on the way out.
        var lateMismatchGeneration = myGeneration
        defer {
            recordLateCertMismatches(from: raced.drain, generation: lateMismatchGeneration)
        }

        let raceEnd = CFAbsoluteTimeGetCurrent()
        AppLog.connection.debug("[ConnectionManager] Connect: raceHosts completed in \(Int((raceEnd - raceStart) * 1000))ms (at +\(Int((raceEnd - connectStart) * 1000))ms)")
        AppLog.connection.debug("[ConnectionManager] Race won by \(winner.host), generation=\(myGeneration)")

        do {
            try Task.checkCancellation()
        } catch {
            await winner.disconnect()
            throw error
        }

        // Check if we've been superseded: a teardown/disconnect advanced the
        // generation, or a newer connect() started (preserving connects share
        // a generation, so the attempt counter carries their ordering).
        guard connectionGeneration == myGeneration, connectAttempt == myAttempt else {
            AppLog.connection.debug("[ConnectionManager] Superseded after race: generation current=\(connectionGeneration) mine=\(myGeneration), attempt current=\(connectAttempt) mine=\(myAttempt)")
            await winner.disconnect()
            throw CancellationError()
        }

        if preservesLiveConnection {
            // The replacement is established: now retire the old connection
            // and adopt the new target's parameters.
            teardownConnection()
            lateMismatchGeneration = connectionGeneration
            self.hosts = hosts
            self.port = port
            self.token = token
            self.certFingerprint = certFingerprint
            self.tcAddress = tcAddress
        }

        self.socket = winner.socket
        self.activeTunnel = winner.tunnel
        self.host = winner.host
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
        hosts: [String], port: Int, token: String, certFingerprint: String?,
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
            if let gate = DemoFixtures.responseGate(for: method, params: params) {
                try await DemoFixtures.wait(for: gate)
            }
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
                id: stored.id, tcAddress: reportedTc
            ) {
                AppLog.connection.warning("[ConnectionManager] Could not persist refreshed tunnel route")
            }
        }

        guard let reported = Self.localIps(fromSystemStatus: result), !reported.isEmpty else {
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
                    id: stored.id, hosts: persistedHosts
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
                id: stored.id, displayName: name
            ) {
                AppLog.connection.warning("[ConnectionManager] Could not persist refreshed display name")
            }
        }
    }

    /// Extracts the `localIps` array from a `system.status` result. Returns nil
    /// when the field is absent (older daemon) or malformed.
    static func localIps(fromSystemStatus result: Any) -> [String]? {
        guard let status = result as? [String: Any],
              let ips = status["localIps"] as? [String] else { return nil }
        return ips
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

    /// A won race: the winner plus the background drain of the candidates
    /// still in flight (`HostRaceOutcome.drain`). The drain is handed to the
    /// caller because only it knows which connection generation the drain's
    /// late mismatches belong to (see `recordLateCertMismatches`).
    private typealias WonHostRace = (
        winner: RacedConnection, drain: Task<[HostCertMismatch], Never>?
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
        let outcome = await Self.raceCandidates(candidates) {
            [certFingerprint, token, tcAddress] candidate in
            let candidateStart = CFAbsoluteTimeGetCurrent()
            if candidate == Self.tunnelCandidateLabel, let tcAddress {
                AppLog.connection.debug("[ConnectionManager] Racing tailcat tunnel")
                let connection = try await Self.connectViaTunnel(
                    dialer: dialer, tcAddress: tcAddress, remotePort: port,
                    token: token, certFingerprint: certFingerprint)
                let elapsed = Int((CFAbsoluteTimeGetCurrent() - candidateStart) * 1000)
                AppLog.connection.debug("[ConnectionManager] Tunnel connected in \(elapsed)ms")
                return connection
            }
            AppLog.connection.debug("[ConnectionManager] Racing host \(candidate):\(port)")
            let connection = try await WebSocketConnection.connect(
                host: candidate,
                port: port,
                token: token,
                certFingerprint: certFingerprint)
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - candidateStart) * 1000)
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
            host: hosts.first ?? "unknown", message: "No reachable host found")
    }

    /// Records the mismatches from candidates still in flight when a race
    /// settled, once the background drain finishes — unless
    /// `connectionGeneration` moved past `generation` by then (a newer
    /// connect() or disconnect() superseded the race).
    private func recordLateCertMismatches(
        from drain: Task<[HostCertMismatch], Never>?, generation: Int
    ) {
        guard let drain else { return }
        Task { [weak self] in
            let lateMismatches = await drain.value
            guard let self, self.connectionGeneration == generation else { return }
            self.recordCertMismatches(lateMismatches)
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
                certFingerprint: certFingerprint)
            return RacedConnection(
                socket: socket, tunnel: tunnel, host: tunnelCandidateLabel)
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
                        host: tunnelCandidateLabel, fingerprint: fingerprint)
                case .invalidURL:
                    throw WebSocketTransportError.invalidURL(host: tunnelCandidateLabel)
                case .missingCertificatePin:
                    throw WebSocketTransportError.missingCertificatePin(host: tunnelCandidateLabel)
                case .timedOut:
                    throw WebSocketTransportError.timedOut(host: tunnelCandidateLabel)
                case .failed(_, let message):
                    throw WebSocketTransportError.failed(
                        host: tunnelCandidateLabel, message: message)
                case .disconnected(_, let code, let reason):
                    throw WebSocketTransportError.disconnected(
                        host: tunnelCandidateLabel, code: code, reason: reason)
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

    /// Races one connect attempt per host and settles on the first success
    /// WITHOUT waiting for the losers: the remaining candidates are cancelled
    /// and drained by a background task (see `HostRaceOutcome.drain`) that
    /// disconnects late successes and reports late certificate mismatches, so
    /// a slow loser never delays an already-won connect. Mismatches observed
    /// before settling are collected on the outcome (a loser's mismatch is not
    /// swallowed by the winner). When no candidate succeeds, every candidate
    /// is awaited and `failure` prefers an aggregate certificate error over
    /// generic failures. Cancelling the losers runs each candidate's task
    /// cancellation handlers synchronously on the settling thread, so
    /// candidate cancellation handlers must not block (the tunnel dial's
    /// `DialHandle.cancel()` closes off-thread for this reason) — a blocking
    /// handler would stall the settle inside `cancelAll()`. Generic over the
    /// connection so tests can race fakes; internal for test visibility.
    nonisolated static func raceCandidates<Connection: HostRacingConnection>(
        _ hosts: [String],
        connect: @escaping @Sendable (String) async throws -> Connection
    ) async -> HostRaceOutcome<Connection> {
        let mailbox = RaceMailbox<Connection>()
        let candidates = hosts.map { host in
            Task {
                do {
                    let connection = try await connect(host)
                    mailbox.deliver(.success(connection))
                } catch {
                    mailbox.deliver(.failure(error))
                }
            }
        }
        let cancelAll = { @Sendable in
            for candidate in candidates { candidate.cancel() }
        }

        return await withTaskCancellationHandler { () -> HostRaceOutcome<Connection> in
            var lastError: Error?
            var mismatches: [HostCertMismatch] = []
            var winner: Connection?
            var cancellationObserved = false
            var remaining = hosts.count
            settle: while remaining > 0 {
                let result = await mailbox.next()
                remaining -= 1
                switch result {
                case .success(let connection):
                    cancelAll()
                    if Task.isCancelled {
                        cancellationObserved = true
                        await connection.disconnect()
                        break settle
                    }
                    winner = connection
                    break settle
                case .failure(let error):
                    if Task.isCancelled {
                        cancellationObserved = true
                        cancelAll()
                    }
                    lastError = error
                    if let transportError = error as? WebSocketTransportError,
                       case .certificateMismatch(let host, let fingerprint) = transportError {
                        mismatches.append(HostCertMismatch(host: host, fingerprint: fingerprint))
                    }
                    AppLog.connection.debug("[ConnectionManager] Host racing: \(error.localizedDescription)")
                    if cancellationObserved { break settle }
                }
            }

            var drain: Task<[HostCertMismatch], Never>?
            if remaining > 0 {
                let pending = remaining
                AppLog.connection.debug("[ConnectionManager] Host racing settled; draining \(pending) candidate(s) in the background")
                drain = Task.detached { () -> [HostCertMismatch] in
                    var lateMismatches: [HostCertMismatch] = []
                    for _ in 0..<pending {
                        switch await mailbox.next() {
                        case .success(let loser):
                            await loser.disconnect()
                        case .failure(let error):
                            if let transportError = error as? WebSocketTransportError,
                               case .certificateMismatch(let host, let fingerprint) = transportError {
                                lateMismatches.append(HostCertMismatch(host: host, fingerprint: fingerprint))
                            }
                            AppLog.connection.debug("[ConnectionManager] Host racing: \(error.localizedDescription)")
                        }
                    }
                    return lateMismatches
                }
            }

            if cancellationObserved || Task.isCancelled {
                if let winner {
                    await winner.disconnect()
                }
                return HostRaceOutcome(
                    winner: nil, mismatches: mismatches, failure: CancellationError(),
                    drain: drain)
            }
            if let winner {
                return HostRaceOutcome(
                    winner: winner, mismatches: mismatches, failure: nil, drain: drain)
            }
            if !mismatches.isEmpty {
                return HostRaceOutcome(
                    winner: nil, mismatches: mismatches,
                    failure: WebSocketTransportError.certificateMismatches(mismatches: mismatches),
                    drain: drain)
            }
            return HostRaceOutcome(
                winner: nil, mismatches: mismatches,
                failure: lastError ?? WebSocketTransportError.failed(
                    host: hosts.first ?? "unknown", message: "No reachable host found"),
                drain: drain)
        } onCancel: {
            cancelAll()
        }
    }

    /// Starts the single serial message pump for `socket`. The pump is
    /// detached so receive + JSON parse run off MainActor (a chat snapshot or
    /// `agent.list` response can be megabytes); it hops to MainActor only to
    /// dispatch the already-parsed frame, awaiting each dispatch before the
    /// next receive so frames are dispatched in receive order.
    private func configureSocketMessagePump() {
        let currentSocket = socket
        messagePumpTask?.cancel()
        guard let currentSocket else { return }
        messagePumpTask = Task.detached { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await currentSocket.receive()
                    guard let self else { return }
                    switch message {
                    case .string(let text):
                        let preview = String(text.prefix(Constants.Connection.logPreviewCharacterLimit))
                        AppLog.connection.debug("[ConnectionManager] Received text: \(preview)...")
                        let parseStart = CFAbsoluteTimeGetCurrent()
                        let frame = Self.parseInboundFrame(text)
                        let parseEnd = CFAbsoluteTimeGetCurrent()
                        guard let frame else { continue }
                        let accepted = await self.acceptInboundFrame(
                            frame, byteCount: text.utf8.count,
                            parseElapsed: parseEnd - parseStart, parseEnd: parseEnd,
                            from: currentSocket)
                        if !accepted { return }
                    case .data(let data):
                        AppLog.connection.debug("[ConnectionManager] Received binary: \(data.count) bytes")
                    @unknown default:
                        AppLog.connection.debug("[ConnectionManager] Received unknown WebSocket message")
                    }
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                await self.handleSocketFailure(error, from: currentSocket)
            }
        }
    }

    /// MainActor half of the pump: dispatches `frame` unless `origin` is no
    /// longer the live socket. Returns `false` when the pump should stop.
    /// `parseEnd` is when the off-main parse finished; the gap to now is the
    /// time the frame spent waiting for MainActor.
    private func acceptInboundFrame(
        _ frame: InboundFrame, byteCount: Int, parseElapsed: TimeInterval, parseEnd: CFAbsoluteTime,
        from origin: WebSocketConnection
    ) -> Bool {
        let waitElapsed = CFAbsoluteTimeGetCurrent() - parseEnd
        guard socket === origin else {
            AppLog.connection.debug("[ConnectionManager] Ignoring message from stale socket")
            return false
        }
        dispatchInboundFrame(frame, byteCount: byteCount, parseElapsed: parseElapsed, waitElapsed: waitElapsed)
        return true
    }

    private func handleSocketFailure(_ error: any Error, from origin: WebSocketConnection) {
        guard socket === origin else { return }
        AppLog.connection.debug("[ConnectionManager] Socket error: \(error.localizedDescription)")
        handleDisconnection()
    }

    /// Turns one inbound frame's text into an `InboundFrame`, or nil for
    /// malformed JSON, a non-object top level, or a frame that is neither a
    /// response (integer `id`) nor a notification (`method`). Pure and
    /// nonisolated: the message pump calls it off MainActor.
    nonisolated static func parseInboundFrame(_ text: String) -> InboundFrame? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        if let id = json["id"] as? Int {
            guard let error = json["error"] as? [String: Any] else {
                return .response(id: id, result: InboundJSONValue(value: json["result"] as Any))
            }
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
            return .error(id: id, error: NSError(
                domain: "WebSocket",
                code: code,
                userInfo: userInfo))
        }
        if let method = json["method"] as? String {
            let params = json["params"] as Any
            if let push = SubscriptionPush.parse(method: method, params: params) {
                return .subscriptionPush(push)
            }
            return .notification(method: method, params: InboundJSONValue(value: params))
        }
        return nil
    }

    /// Synchronous parse + dispatch on MainActor (the `dispatchMessage` test
    /// entry point); the live pump parses off-main instead.
    @MainActor
    private func handleTextMessage(_ text: String) {
        let parseStart = CFAbsoluteTimeGetCurrent()
        guard let frame = Self.parseInboundFrame(text) else { return }
        let parseElapsed = CFAbsoluteTimeGetCurrent() - parseStart
        dispatchInboundFrame(frame, byteCount: text.utf8.count, parseElapsed: parseElapsed, waitElapsed: 0)
    }

    /// Dispatches a parsed frame — resumes the pending request, routes a
    /// subscription push, or broadcasts to the legacy event handlers — and
    /// logs a single slow-frame line when the parse, the MainActor wait, or
    /// this dispatch exceeded `Constants.Connection.slowFrameLogThreshold`.
    @MainActor
    private func dispatchInboundFrame(
        _ frame: InboundFrame, byteCount: Int, parseElapsed: TimeInterval, waitElapsed: TimeInterval
    ) {
        let dispatchStart = CFAbsoluteTimeGetCurrent()
        switch frame {
        case .response(let id, let result):
            pendingRequests.removeValue(forKey: id)?.resume(returning: result.value)
        case .error(let id, let error):
            pendingRequests.removeValue(forKey: id)?.resume(throwing: error)
        case .subscriptionPush(let push):
            subscriptionRouter.route(push)
        case .notification(let method, let params):
            if !subscriptionRouter.route(method: method, params: params.value) {
                // Broadcast other events to all legacy eventHandlers (subscription.push is NOT broadcast)
                for handler in eventHandlers.values {
                    handler(method, params.value)
                }
            }
        }
        let dispatchElapsed = CFAbsoluteTimeGetCurrent() - dispatchStart
        if let line = Self.slowFrameLogLine(
            label: frame.label, byteCount: byteCount, parseElapsed: parseElapsed,
            waitElapsed: waitElapsed, dispatchElapsed: dispatchElapsed,
            threshold: Constants.Connection.slowFrameLogThreshold
        ) {
            AppLog.connection.info("\(line)")
        }
    }

    /// The slow-frame log line, or `nil` when no stage (parse, MainActor
    /// wait, dispatch) exceeded `threshold`.
    nonisolated static func slowFrameLogLine(
        label: String, byteCount: Int, parseElapsed: TimeInterval, waitElapsed: TimeInterval,
        dispatchElapsed: TimeInterval, threshold: TimeInterval
    ) -> String? {
        guard parseElapsed > threshold || waitElapsed > threshold || dispatchElapsed > threshold else {
            return nil
        }
        return "[ConnectionManager] slow frame \(label) bytes=\(byteCount) parse=\(Int(parseElapsed * 1000))ms wait=\(Int(waitElapsed * 1000))ms dispatch=\(Int(dispatchElapsed * 1000))ms"
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
                    let delay = min(
                        Double(1 << min(attempt - 2, Constants.Connection.reconnectBackoffExponentCap)),
                        Constants.Connection.reconnectBackoffMaximum)
                    try? await Task.sleep(for: .seconds(delay))
                    if Task.isCancelled { break }
                }

                let attemptStart = CFAbsoluteTimeGetCurrent()
                AppLog.connection.debug("[ConnectionManager] Reconnect attempt \(attempt) starting at +\(Int((attemptStart - reconnectStart) * 1000))ms")

                // Check freshness before mutating observable state, then read the connection parameters.
                let parameters: ([String], Int, String, String?, String?)?
                if !Task.isCancelled,
                   let self,
                   self.connectionGeneration == myGeneration {
                    self.connectionState = .reconnecting(attempt: attempt)
                    parameters = (
                        self.hosts, self.port ?? 0, self.token ?? "",
                        self.certFingerprint, self.tcAddress)
                } else {
                    parameters = nil
                }
                guard let (hostsToTry, currentPort, currentToken, currentCertFingerprint, currentTcAddress) = parameters else {
                    return
                }

                do {
                    let raceStart = CFAbsoluteTimeGetCurrent()
                    AppLog.connection.debug("[ConnectionManager] raceHosts starting at +\(Int((raceStart - reconnectStart) * 1000))ms")

                    let raced = try await self?.raceHosts(
                        hostsToTry, port: currentPort, token: currentToken,
                        certFingerprint: currentCertFingerprint, tcAddress: currentTcAddress)

                    let raceEnd = CFAbsoluteTimeGetCurrent()
                    AppLog.connection.debug("[ConnectionManager] raceHosts completed in \(Int((raceEnd - raceStart) * 1000))ms")

                    guard let raced else { continue }
                    let winner = raced.winner
                    self?.recordLateCertMismatches(from: raced.drain, generation: myGeneration)

                    do {
                        try Task.checkCancellation()
                    } catch {
                        await winner.disconnect()
                        return
                    }

                    // Batch write: check generation + set up socket + transition to connected synchronously.
                    let genOk: Bool
                    if !Task.isCancelled,
                       let self,
                       self.connectionGeneration == myGeneration {
                        self.socket = winner.socket
                        self.activeTunnel = winner.tunnel
                        self.host = winner.host
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
                        await winner.disconnect()
                        return
                    }

                    let elapsed = (CFAbsoluteTimeGetCurrent() - reconnectStart) * 1000
                    AppLog.connection.debug("[ConnectionManager] Reconnect complete in \(Int(elapsed))ms")
                    return
                } catch {
                    if let transportError = error as? WebSocketTransportError,
                       transportError.isCertificateMismatch || transportError.isMissingCertificatePin {
                        guard !Task.isCancelled,
                              self?.connectionGeneration == myGeneration else { return }
                        AppLog.connection.debug("[ConnectionManager] Certificate trust failure (\(transportError.localizedDescription)), stopping reconnection")
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

    /// The one global `events.subscribe` list. Every channel a store classifies
    /// (`handledChannels`) must appear here as `<channel>*`, or that store's
    /// classification never receives an event — enforced by
    /// `IntentTests/EventCatalogCoverageTests.swift`.
    nonisolated static let globalEventTypes = ["workspace:*", "note:*", "agent:*", "task:*"]

    private func subscribeToAllEvents() {
        Task {
            do {
                let _ = try await self.request("events.subscribe", params: [
                    "eventTypes": Self.globalEventTypes,
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
