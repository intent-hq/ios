import Combine
import Foundation
import Observation
import os

@MainActor
@Observable class ConnectionManager: ConnectionManagerRouting {
    nonisolated enum GlobalSubscriptionState: Equatable, Sendable {
        case idle
        case subscribing(attempt: Int)
        case subscribed
        case failed(attempts: Int, lastError: String)
    }

    private struct ConnectTarget {
        let hosts: [String]
        let port: Int
        let token: String
        let certFingerprint: String?
        let tcAddress: String?
        let pairingAttemptID = PairingConnectionContext.attemptID
    }

    private struct ConnectAttemptContext {
        let generation: Int
        let attempt: Int
        let preservesLiveConnection: Bool
        let certMismatchesBeforeAttempt: [HostCertMismatch]
    }

    static let shared = ConnectionManager()

    var connectionState: ConnectionState = .disconnected {
        didSet {
            if connectionState == .connected { reconnectStopReason = nil }
            if isInProcessConnection {
                globalSubscriptionState = connectionState == .connected ? .subscribed : .idle
            }
            connectionStateSubject.send(connectionState)
        }
    }
    /// Why reconnection stopped for good (e.g. revoked access); cleared on connect.
    var reconnectStopReason: String?
    /// Set while connected without a daemon socket (pretend-paired launches);
    /// readiness then follows the connection state directly.
    @ObservationIgnored private var isInProcessConnection = false
    /// Answers requests in process instead of over the socket when set.
    @ObservationIgnored private(set) var requestTransport: (any ConnectionRequestTransport)?

    @ObservationIgnored var scriptMonitorsDisabledForConnection = false
    var capabilities: ConnectionCapabilities = .unknown {
        didSet { capabilitiesSubject.send(capabilities) }
    }
    @ObservationIgnored private let capabilitiesSubject = CurrentValueSubject<ConnectionCapabilities, Never>(.unknown)
    var capabilitiesPublisher: AnyPublisher<ConnectionCapabilities, Never> { capabilitiesSubject.eraseToAnyPublisher() }
    private var admittedPrincipal: ConnectionPrincipal?
    @ObservationIgnored var admission: ConnectionAdmission?
    @ObservationIgnored private(set) var pairingAttemptID: UUID?
    var currentPrincipal: ConnectionPrincipal? {
        get { requestTransport?.principal ?? admittedPrincipal }
        set { admittedPrincipal = newValue }
    }
    @ObservationIgnored var lastConnectedPrincipal: ConnectionPrincipal?
    @ObservationIgnored var authorityRefreshTask: Task<Void, Never>?
    @ObservationIgnored var pendingAuthorityRevision: Double = -1
    @ObservationIgnored var authorityBeforeRefresh: ConnectionPrincipal?
    var startupState: DaemonStartupState?
    @ObservationIgnored var startupRun = StartupAdmissionRun()

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
    @ObservationIgnored let subscriptionRouter: ConnectionSubscriptionRouter
    @ObservationIgnored let diagnostics: DiagnosticStore
    @ObservationIgnored let persistence: PersistenceManager

    @ObservationIgnored var socket: WebSocketConnection?
    @ObservationIgnored var messagePumpTask: Task<Void, Never>?
    @ObservationIgnored var pendingRequests: [Int: CheckedContinuation<Any, Error>] = [:]
    @ObservationIgnored private var nextRequestId = 1
    @ObservationIgnored private(set) var connectionGeneration: Int = 0
    @ObservationIgnored private(set) var reconnectCredentialsRevision = 0
    /// Supersession order among overlapping `connect()` calls. The preserving
    /// path (pairing over a live connection) does not tear down — and so does
    /// not advance `connectionGeneration` — up front, so overlapping attempts
    /// share a generation; this counter ensures the NEWEST attempt wins the
    /// adoption race regardless of which one finishes first.
    @ObservationIgnored private var connectAttempt: Int = 0
    @ObservationIgnored var reconnectTask: Task<Void, Never>?
    /// Read by tests as a completion barrier for a retired heartbeat.
    @ObservationIgnored var heartbeatTask: Task<Void, Never>?
    @ObservationIgnored var globalSubscriptionTask: Task<Void, Never>?
    /// Time source for heartbeat cadence/probe deadlines and subscription retry backoff.
    @ObservationIgnored var heartbeatClock: any HeartbeatClock = ContinuousHeartbeatClock()
    /// A fresh path monitor is created for every live socket because NWPathMonitor is one-shot.
    @ObservationIgnored var makePathMonitor: () -> any NetworkPathMonitoring = {
        NWPathMonitorAdapter()
    }
    @ObservationIgnored var pathMonitor: (any NetworkPathMonitoring)?
    @ObservationIgnored var pathMonitorID = 0
    @ObservationIgnored var lastPathSnapshot: NetworkPathSnapshot?
    /// Injectable endpoint evidence; general path reports cannot disprove a direct route.
    @ObservationIgnored var readSocketPath: (WebSocketConnection) -> SocketPathObservation = { socket in
        socket.pathObservation
    }
    @ObservationIgnored var socketPathObservation: SocketPathObservation?
    @ObservationIgnored var socketInterface: String?
    @ObservationIgnored var lastSuccessfulConnectAt: CFAbsoluteTime?
    @ObservationIgnored var lastReconnectAttempt = 0
    nonisolated private static let heartbeatIntervalSeconds = 15
    nonisolated private static let heartbeatProbeTimeoutSeconds = 30
    nonisolated static let heartbeatInterval: Duration = .seconds(heartbeatIntervalSeconds)
    nonisolated static let heartbeatProbeTimeout: Duration = .seconds(heartbeatProbeTimeoutSeconds)
    nonisolated static let millisecondsPerSecond: CFTimeInterval = 1000
    @ObservationIgnored private(set) var hosts: [String] = []
    @ObservationIgnored var host: String?
    @ObservationIgnored private(set) var port: Int?
    @ObservationIgnored private(set) var token: String?
    @ObservationIgnored private(set) var certFingerprint: String?
    /// Tailcat tunnel address of the current target (nil when the daemon has
    /// no tunnel); adds the tunnel candidate to host racing when present.
    @ObservationIgnored private(set) var tcAddress: String?
    /// The tunnel session carrying the live socket (nil when a direct host
    /// won the race); closed on teardown.
    @ObservationIgnored var activeTunnel: (any TunnelSession)?
    /// Injectable for tests; defaults to the real TailcatKit-backed dialer
    /// where the xcframework links (iOS), and to the always-failing stub on
    /// visionOS (no xros TailcatKit slice yet).
    #if canImport(TailcatKit)
    @ObservationIgnored var tunnelDialer: any TunnelDialing = TailcatTunnelDialer()
    #else
    @ObservationIgnored var tunnelDialer: any TunnelDialing = UnavailableTunnelDialer()
    #endif

    @ObservationIgnored var eventHandlers: [UUID: (String, Any) -> Void] = [:]
    @ObservationIgnored private let globalSubscriptionSubject = CurrentValueSubject<GlobalSubscriptionState, Never>(.idle)
    var globalSubscriptionState: GlobalSubscriptionState = .idle {
        didSet { globalSubscriptionSubject.send(globalSubscriptionState) }
    }
    var globalSubscriptionPublisher: AnyPublisher<GlobalSubscriptionState, Never> {
        globalSubscriptionSubject.eraseToAnyPublisher()
    }

    /// The candidate label the tunnel route races under (also the host shown
    /// in its transport errors). Not a dialable name: the tunnel connects via
    /// a loopback forwarder.
    nonisolated static let tunnelCandidateLabel = "tailcat-tunnel"

    /// Internal (not private) so `BackendSessionRegistry` can construct one
    /// additional instance per pinned backend session; `.shared` remains the
    /// process-wide default used by the default session and existing code.
    init(diagnostics: DiagnosticStore = .shared, persistence: PersistenceManager = .shared) {
        self.diagnostics = diagnostics
        self.persistence = persistence
        subscriptionRouter = ConnectionSubscriptionRouter(diagnostics: diagnostics)
        requestTransport = Self.makeInProcessTransport(serveFixtures: false)
        observeStartupLifecycle()
    }

    isolated deinit {
        requestTransport?.stop()
        authorityRefreshTask?.cancel()
        stopPathMonitor()
    }
}

extension ConnectionManager {
    /// Demo sessions use fixture pushes instead of a socket's remote feed.
    /// Keep readiness tied to the same connection transitions as their stores.
    func connectDemo(serveFixtures: Bool) {
        connectInProcess(using: Self.makeInProcessTransport(serveFixtures: serveFixtures))
    }

    /// Marks the connection live without a socket; requests go to `transport`.
    func connectInProcess(using transport: (any ConnectionRequestTransport)?) {
        if !isInProcessConnection { disconnect() }
        isInProcessConnection = true
        replaceRequestTransport(with: transport)
        connectionState = .connected
    }

    /// Installs `transport` and adopts the capabilities it advertises.
    func replaceRequestTransport(with transport: (any ConnectionRequestTransport)?) {
        requestTransport?.stop()
        requestTransport = transport
        capabilities = transport?.capabilities ?? .unknown
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

    /// A manual retry skips transport backoff without replacing an already
    /// connected socket or an initial connection attempt. Pin failures still
    /// require the pairing flow, never an untrusted reconnect.
    func retryConnection() {
        guard connectionState != .connected, connectionState != .connecting,
              !certMismatchDetected, !hosts.isEmpty || tcAddress != nil,
              port != nil, token != nil else { return }
        startReconnection()
    }

    func connect(
        hosts: [String],
        port: Int,
        token: String,
        certFingerprint: String? = nil,
        tcAddress: String? = nil
    ) async throws {
        let scope = diagnostics.makeScope()
        let origin = DiagnosticConnectContext.origin
        recordConnectionAttempt(.started, context: origin, scope: scope)
        do {
            try await performConnect(hosts: hosts, port: port, token: token, certFingerprint: certFingerprint, tcAddress: tcAddress)
            recordConnectionAttempt(.succeeded, context: activeTunnel == nil ? .direct : .tunnel, scope: scope)
        } catch {
            let cancelled = error is CancellationError || Task.isCancelled
            recordConnectionAttempt(
                cancelled ? .cancelled : .failed,
                failure: cancelled ? .none : TransportDiagnosticFailure.classify(error),
                context: origin,
                scope: scope
            )
            throw error
        }
    }

    private func performConnect(
        hosts: [String], port: Int, token: String, certFingerprint: String?, tcAddress: String?
    ) async throws {
        try validateTransportSecurity(hosts: hosts, certFingerprint: certFingerprint)
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
        let raced: AdmittedHostRace
        do {
            raced = try await readyRace(token: target.token, fingerprint: target.certFingerprint) { try await self.raceHosts(target) }
        } catch {
            restoreCertMismatchesAfterFailedConnect(context)
            throw error
        }
        let winner = raced.winner
        var lateMismatchGeneration = context.generation
        defer { recordLateCertMismatches(from: raced.drain, generation: lateMismatchGeneration) }
        let raceEnd = CFAbsoluteTimeGetCurrent()
        AppLog.connection.debug("[ConnectionManager] Connect: raceHosts completed in \(Int((raceEnd - raceStart) * Self.millisecondsPerSecond))ms (at +\(Int((raceEnd - connectStart) * Self.millisecondsPerSecond))ms)")
        AppLog.connection.debug("[ConnectionManager] Race won by \(winner.host), generation=\(context.generation)")
        guard !Task.isCancelled else {
            await winner.disconnect()
            throw CancellationError()
        }
        guard connectionGeneration == context.generation, connectAttempt == context.attempt else {
            AppLog.connection.debug("[ConnectionManager] Superseded after race: generation current=\(connectionGeneration) mine=\(context.generation), attempt current=\(connectAttempt) mine=\(context.attempt)")
            await winner.disconnect()
            throw CancellationError()
        }
        lateMismatchGeneration = adoptConnectedWinner(
            winner,
            handshake: raced.handshake,
            target: target,
            preservesLiveConnection: context.preservesLiveConnection,
            initialGeneration: context.generation
        )
        let setupEnd = CFAbsoluteTimeGetCurrent()
        AppLog.connection.debug("[ConnectionManager] Connect: socket setup completed in \(Int((setupEnd - raceEnd) * Self.millisecondsPerSecond))ms (at +\(Int((setupEnd - connectStart) * Self.millisecondsPerSecond))ms)")
        let totalElapsed = CFAbsoluteTimeGetCurrent() - connectStart
        AppLog.connection.debug("[ConnectionManager] Connect: total elapsed \(Int(totalElapsed * Self.millisecondsPerSecond))ms, connected to \(self.host ?? "?")")
    }

    private func validateTransportSecurity(hosts: [String], certFingerprint: String?) throws {
        // Fail closed before touching state or opening a socket: otherwise a
        // pinless saved record could send its bearer token over plaintext.
        guard WebSocketConnection.trustedPin(certFingerprint) != nil
            || WebSocketConnection.plaintextLoopbackOverrideActive else {
            throw WebSocketTransportError.missingCertificatePin(host: hosts.first ?? "unknown")
        }
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
        handshake: ConnectionHandshake,
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
        finishIdentityAdmission(handshake, token: target.token, fingerprint: target.certFingerprint)
        lastSuccessfulConnectAt = CFAbsoluteTimeGetCurrent()
        lastReconnectAttempt = 0
        subscribeToAllEvents()
        startHeartbeat()
        startPathMonitor()
        scheduleHostRoutesRefresh()
        return lateMismatchGeneration
    }

    private func cacheConnectTarget(_ target: ConnectTarget) {
        pairingAttemptID = target.pairingAttemptID
        updateCachedCredentials(
            hosts: target.hosts,
            port: target.port,
            token: target.token,
            certFingerprint: target.certFingerprint,
            tcAddress: target.tcAddress
        )
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
        if self.hosts != hosts || self.port != port || self.token != token || self.certFingerprint != certFingerprint || self.tcAddress != tcAddress {
            reconnectCredentialsRevision += 1
        }
        self.hosts = hosts
        self.port = port
        self.token = token
        self.certFingerprint = certFingerprint
        self.tcAddress = tcAddress
    }

    func disconnect() {
        if connectionState != .disconnected {
            diagnostics.record(DiagnosticEvent(
                kind: .connectionTransition,
                operation: .connectionTransition,
                site: .connectionManager,
                stage: .cleanup,
                outcome: .changed,
                context: .explicitDisconnect
            ))
        }
        teardownConnection()
        if !certMismatches.isEmpty { certMismatches = [] }
    }

    /// Tears down the live connection without touching `certMismatches`:
    /// `connect()` to the same target must keep the accumulated mismatches,
    /// while an explicit `disconnect()` clears them.
    private func teardownConnection() {
        cancelStartupAdmission()
        requestTransport?.stop()
        requestTransport = Self.makeInProcessTransport(serveFixtures: false)
        isInProcessConnection = false
        connectionGeneration += 1
        pairingAttemptID = nil
        clearPrincipal()
        lastConnectedPrincipal = nil
        stopHeartbeat()
        stopPathMonitor()
        stopGlobalSubscription()
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

    func takeNextRequestId() -> Int {
        defer { nextRequestId += 1 }
        return nextRequestId
    }

    func applyRefreshedHosts(_ refreshedHosts: [String]) {
        if hosts != refreshedHosts { reconnectCredentialsRevision += 1 }
        hosts = refreshedHosts
    }

    func applyRefreshedTunnelAddress(_ refreshedAddress: String?) {
        if tcAddress != refreshedAddress { reconnectCredentialsRevision += 1 }
        tcAddress = refreshedAddress
    }
}
