import Foundation

extension ConnectionManager {
    /// Sleeps for one cadence interval, then probes the live socket. Probes are
    /// sequential and generation/socket guarded so a retired result is ignored.
    func startHeartbeat() {
        stopHeartbeat()
        let generation = connectionGeneration
        let clock = heartbeatClock
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: Self.heartbeatInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                await probeConnectionHealth(generation: generation)
            }
        }
    }

    func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func probeConnectionHealth(generation: Int) async {
        guard !Task.isCancelled,
              connectionGeneration == generation,
              connectionState == .connected,
              let currentSocket = socket else { return }
        let clock = heartbeatClock
        do {
            try await Self.probe(
                currentSocket,
                timeout: Self.heartbeatProbeTimeout,
                clock: clock
            )
            guard !Task.isCancelled,
                  connectionGeneration == generation,
                  socket === currentSocket else {
                AppLog.connection.debug(
                    "[ConnectionManager] Ignoring late pong from retired heartbeat "
                        + "(generation \(generation))"
                )
                return
            }
            AppLog.connection.debug("[ConnectionManager] Received pong")
        } catch {
            guard !Task.isCancelled,
                  !(error is CancellationError),
                  connectionGeneration == generation,
                  socket === currentSocket else {
                AppLog.connection.debug(
                    "[ConnectionManager] Ignoring heartbeat probe outcome from retired "
                        + "generation \(generation)"
                )
                return
            }
            AppLog.connection.debug(
                "[ConnectionManager] Heartbeat probe failed: \(error.localizedDescription), "
                    + "triggering reconnection"
            )
            handleDisconnection()
        }
    }

    nonisolated private static func probe(
        _ socket: WebSocketConnection,
        timeout: Duration,
        clock: any HeartbeatClock
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await socket.sendPing() }
            group.addTask {
                try await clock.sleep(for: timeout)
                throw WebSocketTransportError.timedOut(host: socket.host)
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}
