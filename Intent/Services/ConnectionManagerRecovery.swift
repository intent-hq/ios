import Foundation

extension ConnectionManager {
    private static let stableConnectionThreshold: TimeInterval = 10
    nonisolated private static let initialReconnectAttempt: Int = 1
    nonisolated private static let minimumBackedOffReconnectAttempt: Int = 2

    private struct ReconnectParameters {
        let hosts: [String]
        let port: Int
        let token: String
        let certFingerprint: String?
        let tcAddress: String?
    }

    static func reconnectStartingAttempt(
        connectionLifetime: TimeInterval?,
        previousAttempt: Int
    ) -> Int {
        guard let connectionLifetime,
              connectionLifetime < stableConnectionThreshold else { return initialReconnectAttempt }
        return max(previousAttempt + initialReconnectAttempt, minimumBackedOffReconnectAttempt)
    }

    // MARK: - Host Racing

    /// A won race: the winner plus the background drain of the candidates
    /// still in flight (`HostRaceOutcome.drain`). The drain is handed to the
    /// caller because only it knows which connection generation the drain's
    /// late mismatches belong to (see `recordLateCertMismatches`).
    typealias WonHostRace = (
        winner: RacedConnection,
        drain: Task<[HostCertMismatch], Never>?
    )

    func raceHosts(
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
    func recordLateCertMismatches(
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
                case .missingCertificatePin:
                    throw WebSocketTransportError.missingCertificatePin(
                        host: tunnelCandidateLabel
                    )
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

    func configureSocketMessagePump() {
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
                        let accepted = await acceptInboundFrame(
                            frame,
                            byteCount: text.utf8.count,
                            parseElapsed: parseEnd - parseStart,
                            parseEnd: parseEnd,
                            from: currentSocket
                        )
                        if !accepted { return }
                    case .data(let data):
                        AppLog.connection.debug("[ConnectionManager] Received binary: \(data.count) bytes")
                    @unknown default:
                        AppLog.connection.debug("[ConnectionManager] Received unknown WebSocket message")
                    }
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                await handleSocketFailure(error, from: currentSocket)
            }
        }
    }

    func acceptInboundFrame(
        _ frame: InboundFrame,
        byteCount: Int,
        parseElapsed: TimeInterval,
        parseEnd: CFAbsoluteTime,
        from origin: WebSocketConnection
    ) -> Bool {
        let waitElapsed = CFAbsoluteTimeGetCurrent() - parseEnd
        guard socket === origin else {
            AppLog.connection.debug("[ConnectionManager] Ignoring message from stale socket")
            return false
        }
        dispatchInboundFrame(
            frame,
            byteCount: byteCount,
            parseElapsed: parseElapsed,
            waitElapsed: waitElapsed
        )
        return true
    }

    func handleSocketFailure(_ error: any Error, from origin: WebSocketConnection) {
        guard socket === origin else { return }
        AppLog.connection.debug("[ConnectionManager] Socket error: \(error.localizedDescription)")
        handleDisconnection()
    }

    func handleDisconnection() {
        let disconnectTime = CFAbsoluteTimeGetCurrent()
        AppLog.connection.debug("[ConnectionManager] handleDisconnection called, current state=\(connectionState)")
        guard connectionState != .disconnected else {
            AppLog.connection.debug("[ConnectionManager] Already disconnected, ignoring")
            return
        }
        stopHeartbeat()
        stopPathMonitor()
        stopGlobalSubscription()
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
        startHeartbeat()
        startPathMonitor()
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

    // MARK: - Network path monitoring

    func startPathMonitor() {
        stopPathMonitor()
        pathMonitorID += 1
        let monitorID = pathMonitorID
        if let socket {
            let observation = readSocketPath(socket)
            socketPathObservation = observation
            let path = observation.current?.path
            socketInterface = path?.isOnPhysicalInterface == true ? path?.primaryInterface : nil
            let generation = connectionGeneration
            observation.observe { @Sendable [weak self, weak socket, weak observation] in
                Task { @MainActor in
                    guard let self, let socket, let observation,
                          self.socket === socket, self.connectionGeneration == generation,
                          self.pathMonitorID == monitorID, self.socketPathObservation === observation,
                          self.connectionState == .connected, observation.current?.isLost == true else { return }
                    self.handleDisconnection()
                }
            }
        }
        let monitor = makePathMonitor()
        pathMonitor = monitor
        monitor.start { [weak self] snapshot in
            self?.handlePathUpdate(snapshot, monitorID: monitorID)
        }
    }

    func stopPathMonitor() {
        socketPathObservation?.removeObserver()
        socketPathObservation = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathSnapshot = nil
        socketInterface = nil
    }

    private func handlePathUpdate(_ snapshot: NetworkPathSnapshot, monitorID: Int) {
        guard pathMonitorID == monitorID, pathMonitor != nil else { return }
        let previous = lastPathSnapshot
        lastPathSnapshot = snapshot
        // An embedded tunnel's local socket cannot observe its remote underlay.
        // Direct sockets (including system VPNs) use only their endpoint evidence.
        guard connectionState == .connected, socket != nil, activeTunnel != nil else { return }

        let pathDied: Bool
        if let previous {
            pathDied = previous.isSatisfied && !snapshot.isSatisfied
        } else {
            pathDied = !snapshot.isSatisfied
        }
        // Preference/virtual-name changes alone do not invalidate a serving tunnel.
        let previousPhysicalInterface = previous?.physicalInterfaces.first
        let physicalInterfaceLost = previousPhysicalInterface.map { interface in
            snapshot.isSatisfied && !snapshot.availableInterfaces.contains(interface)
        } ?? false
        guard pathDied || physicalInterfaceLost else { return }
        AppLog.connection.debug(
            "[ConnectionManager] Network path changed (\(String(describing: previous)) -> "
                + "\(String(describing: snapshot))), reconnecting"
        )
        handleDisconnection()
    }
}
